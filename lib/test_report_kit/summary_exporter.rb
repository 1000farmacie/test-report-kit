# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module TestReportKit
  class SummaryExporter
    def initialize(metrics:, diff_coverage:, config: TestReportKit.configuration)
      @metrics       = metrics
      @diff_coverage = diff_coverage
      @config        = config
    end

    def export
      output_path = File.join(@config.output_dir, "summary.json")
      FileUtils.mkdir_p(@config.output_dir)

      # Rotate current → previous before building (so delta can be computed)
      previous_path = File.join(@config.output_dir, "previous_summary.json")
      FileUtils.cp(output_path, previous_path) if File.exist?(output_path)

      summary = build_summary
      File.write(output_path, JSON.pretty_generate(summary))
      output_path
    end

    private

    def build_summary
      cov = @metrics[:overall_coverage]
      rspec = @metrics[:rspec_summary]
      slowest = @metrics[:slowest_tests] || []
      factory = @metrics[:factory_health]
      risks = (@metrics[:risk_scores] || []).first(3)

      previous = load_previous
      delta = compute_delta(cov, previous)

      {
        coverage_pct: cov&.dig(:coverage_pct),
        coverage_delta: delta,
        branch_coverage_pct: cov&.dig(:branch_coverage_pct),

        diff_coverage_pct: @diff_coverage&.diff_coverage_pct,
        diff_coverage_passed: @diff_coverage&.passed,
        diff_coverage_threshold: @diff_coverage&.threshold || @config.diff_coverage_threshold,
        diff_changed_lines: @diff_coverage&.total_changed_lines,
        diff_executable_lines: @diff_coverage&.executable_changed_lines,
        diff_covered_lines: @diff_coverage&.covered_changed_lines,
        diff_uncovered_lines: @diff_coverage&.uncovered_changed_lines,
        diff_uncovered_files: uncovered_files_summary,

        duration_seconds: rspec&.dig(:duration_seconds),
        duration_formatted: rspec&.dig(:duration_formatted),
        total_examples: rspec&.dig(:example_count),
        failed_examples: rspec&.dig(:failure_count),
        pending_examples: rspec&.dig(:pending_count),

        slowest_test_name: slowest.first&.dig(:description),
        slowest_test_duration: slowest.first&.dig(:duration),
        slowest_tests: slowest.first(5).map { |t| { description: t[:description], file: t[:file], duration: t[:duration] } },

        total_factory_creates: factory&.dig(:total_count),

        top_risks: risks.map { |r| { file: r[:path], coverage: r[:coverage_pct], churn: r[:churn] } },

        peak_memory_mb: load_resource_field("peak_memory_mb"),
        cpu_user_seconds: load_resource_field("cpu_user_seconds"),

        generated_at: Time.now.iso8601,
        branch: ENV.fetch("TEST_REPORT_BRANCH", `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip),
        sha: ENV.fetch("TEST_REPORT_SHA", `git rev-parse --short HEAD 2>/dev/null`.strip)
      }
    end

    def uncovered_files_summary
      return [] unless @diff_coverage

      @diff_coverage.files
        .select { |f| f.uncovered_lines.any? }
        .map { |f| { file: f.path, diff_coverage_pct: f.diff_coverage_pct, uncovered_count: f.uncovered_lines.size } }
    end

    def load_resource_field(field)
      path = File.join(@config.output_dir, "resource_usage.json")
      return nil unless File.exist?(path)
      JSON.parse(File.read(path))[field]
    rescue StandardError => e
      warn "TestReportKit: Failed to load resource field '#{field}': #{e.message}"
      nil
    end

    def load_previous
      path = File.join(@config.output_dir, "previous_summary.json")
      return nil unless File.exist?(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      warn "TestReportKit: Failed to parse previous summary: #{e.message}"
      nil
    end

    def compute_delta(current_cov, previous)
      return nil unless current_cov && previous && previous["coverage_pct"]
      diff = (current_cov[:coverage_pct] - previous["coverage_pct"]).round(1)
      diff >= 0 ? "+#{diff}" : diff.to_s
    end
  end
end
