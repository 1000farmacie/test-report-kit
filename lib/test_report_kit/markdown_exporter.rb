# frozen_string_literal: true

require "fileutils"
require "time"

module TestReportKit
  class MarkdownExporter
    # GitHub PR/issue comment bodies are capped at 65,536 chars. Stay well below so
    # callers (e.g. CI workflows) can prepend headers / append download links without
    # blowing the limit.
    MAX_BYTES = 60_000

    def initialize(metrics:, diff_coverage:, config: TestReportKit.configuration)
      @metrics       = metrics
      @diff_coverage = diff_coverage
      @config        = config
    end

    def export
      output_path = File.join(@config.output_dir, "report.md")
      FileUtils.mkdir_p(@config.output_dir)
      File.write(output_path, build)
      output_path
    end

    # The comment is intentionally split into two scopes:
    #   1. **Overall** — totals over the whole suite (coverage %, test count,
    #      duration, factory creates). No per-file lists.
    #   2. **This PR** — only files changed on the current branch + the rspec
    #      examples whose spec file maps to one of those source files (mapped
    #      by Rails convention in MetricsCalculator#candidate_spec_paths).
    #
    # Per-file detail (low-coverage tables, global insights) is intentionally
    # omitted — the full HTML report covers that and the comment should stay
    # actionable for the reviewer reading a PR.
    def build
      @build ||= begin
        sections = []
        sections << header_section
        sections << overall_section
        sections << pr_section
        sections << diff_coverage_section
        sections << action_items_section
        body = sections.compact.join("\n\n---\n\n")
        truncate(body)
      end
    end

    private

    def truncate(body)
      return body if body.bytesize <= MAX_BYTES

      notice = "\n\n---\n\n_Report truncated (#{body.bytesize} → #{MAX_BYTES} bytes). " \
               "See the full HTML report in the workflow artifact._\n"
      keep = MAX_BYTES - notice.bytesize
      body.byteslice(0, keep) + notice
    end

    def header_section
      "# Test Report: #{@config.resolved_project_name}\n\n" \
      "Generated: #{Time.now.iso8601}  \n" \
      "Branch: `#{branch}` | SHA: `#{sha}`"
    end

    def overall_section
      cov = @metrics[:overall_coverage]
      rspec = @metrics[:rspec_summary]
      factory = @metrics[:factory_health]

      lines = ["## Overall\n"]
      lines << "| Metric | Value |"
      lines << "|--------|-------|"
      if cov
        lines << "| Line Coverage | #{cov[:coverage_pct]}% (#{cov[:covered_lines]}/#{cov[:total_lines]}) |"
        lines << "| Branch Coverage | #{cov[:branch_coverage_pct]}% |"
      end
      if rspec
        lines << "| Tests | #{rspec[:example_count]} examples (#{rspec[:failure_count]} failures, #{rspec[:pending_count]} pending) |"
        lines << "| Duration | #{rspec[:duration_formatted]} |"
      end
      lines << "| Factory Creates | #{factory[:total_count]} |" if factory
      lines.join("\n")
    end

    def pr_section
      pr = @metrics[:pr_metrics]
      return nil unless pr && pr[:file_count] > 0

      lines = ["## This PR\n"]
      lines << "| Metric | Value |"
      lines << "|--------|-------|"
      lines << "| Files changed | #{pr[:file_count]} |"
      diff_pct = pr[:diff_coverage_pct] ? "#{pr[:diff_coverage_pct]}%" : "N/A"
      gate = "(gate #{pr[:diff_coverage_threshold]}% — #{pr[:diff_coverage_passed] ? 'PASS' : 'FAIL'})"
      lines << "| Diff Coverage | #{diff_pct} #{gate} |"
      if pr[:related_test_count] > 0
        lines << "| Related tests | #{pr[:related_test_count]} examples (#{pr[:related_passes]} passed, #{pr[:related_failures]} failed) |"
        lines << "| Related test time | #{pr[:related_total_test_time_formatted]} |"
      end

      if pr[:files].any?
        lines << ""
        lines << "### Files changed"
        lines << "| File | Diff Coverage | Uncovered |"
        lines << "|------|---------------|-----------|"
        pr[:files].each do |f|
          pct = f[:not_loaded] ? "not loaded" : (f[:coverage_pct] ? "#{f[:coverage_pct]}%" : "N/A")
          lines << "| `#{f[:path]}` | #{pct} | #{f[:uncovered]} |"
        end
      end

      if pr[:related_slowest_tests].any?
        lines << ""
        lines << "### Slowest related tests"
        lines << "| Test | Duration | Status |"
        lines << "|------|----------|--------|"
        pr[:related_slowest_tests].each do |t|
          desc = t[:description].to_s[0..80]
          lines << "| #{desc} | #{t[:duration]}s | #{t[:status]} |"
        end
      end

      lines.join("\n")
    end

    def diff_coverage_section
      return nil unless @diff_coverage

      relevant = @diff_coverage.files.select { |f| f.uncovered_lines.any? || f.not_loaded }
      return nil if relevant.empty?

      lines = ["## Uncovered Changes\n"]
      relevant.each do |f|
        status = f.not_loaded ? "NOT LOADED BY TESTS" : "#{f.diff_coverage_pct}%"
        lines << "### `#{f.path}` — #{status}\n"

        if f.not_loaded
          lines << "> This file was never loaded during the test suite. All #{f.uncovered_lines.size} changed lines are uncovered.\n"
          next
        end

        lines << "Uncovered lines: `#{f.uncovered_lines.join(', ')}`\n"
        lines << "```ruby"
        f.uncovered_content.each do |entry|
          next if entry[:type] == :gap
          prefix = entry[:type] == :uncovered ? "- " : "  "
          lines << "#{prefix}#{entry[:line]}: #{entry[:content]}"
        end
        lines << "```"
      end
      lines.join("\n")
    end

    def action_items_section
      items = []

      if @diff_coverage&.passed == false
        items << "- [ ] **Diff coverage below threshold** (#{@diff_coverage.diff_coverage_pct}% < #{@diff_coverage.threshold}%)"
        @diff_coverage.files.select { |f| f.uncovered_lines.any? }.each do |f|
          items << "  - `#{f.path}`: #{f.uncovered_lines.size} uncovered lines"
        end
      end

      pr = @metrics[:pr_metrics]
      if pr && pr[:related_failures].to_i > 0
        items << "- [ ] **#{pr[:related_failures]} failing test(s) in PR-related files**"
      end

      return nil if items.empty?
      (["## Action Items\n"] + items).join("\n")
    end

    def branch
      ENV.fetch("TEST_REPORT_BRANCH", `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip)
    end

    def sha
      ENV.fetch("TEST_REPORT_SHA", `git rev-parse --short HEAD 2>/dev/null`.strip)
    end
  end
end
