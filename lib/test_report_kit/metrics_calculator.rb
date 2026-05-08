# frozen_string_literal: true

module TestReportKit
  class MetricsCalculator
    def initialize(simplecov_data:, rspec_data:, factory_prof_data:,
                   event_prof_data:, rspec_dissect_data:, git_churn_data:,
                   diff_coverage:, config: TestReportKit.configuration)
      @simplecov     = simplecov_data
      @rspec         = rspec_data
      @factory_prof  = factory_prof_data
      @event_prof    = event_prof_data
      @rspec_dissect = rspec_dissect_data
      @git_churn     = git_churn_data
      @diff_coverage = diff_coverage
      @config        = config
    end

    def call
      {
        overall_coverage: overall_coverage,
        file_coverage: file_coverage_list,
        rspec_summary: rspec_summary,
        slowest_tests: slowest_tests,
        failed_tests: failed_tests,
        test_time_distribution: test_time_distribution,
        time_by_file: time_by_file,
        factory_health: factory_health,
        risk_scores: risk_scores,
        insights: insights,
        pr_metrics: pr_metrics
      }
    end

    private

    # ── PR scope ──
    #
    # When diff coverage is available we expose a "PR scope" — the set of
    # source files changed in the current branch plus the rspec examples
    # whose spec file maps to one of those source files (Rails convention:
    # `app/X/Y.rb` ↔ `spec/X/Y_spec.rb`, `lib/X.rb` ↔ `spec/X_spec.rb` or
    # `spec/lib/X_spec.rb`). Used by the dashboard's PR-only filter and by
    # the markdown exporter to scope the comment to PR-related metrics.

    def pr_metrics
      return nil unless @diff_coverage

      pr_paths = @diff_coverage.files.map(&:path)
      pr_spec_paths = pr_paths.flat_map { |p| candidate_spec_paths(p) }.uniq

      pr_examples = (@rspec&.dig("examples") || []).select do |e|
        spec_path = e["file_path"].to_s.sub(%r{^\./}, "")
        pr_spec_paths.include?(spec_path)
      end

      total_time = pr_examples.sum { |e| (e["run_time"] || 0).to_f }
      slowest = pr_examples
        .select { |e| e["run_time"] && e["status"] != "pending" }
        .sort_by { |e| -e["run_time"] }
        .first(5)
        .map { |e| map_test(e) }

      passes = pr_examples.count { |e| e["status"] == "passed" }
      failures = pr_examples.count { |e| e["status"] == "failed" }

      {
        file_count: pr_paths.size,
        diff_coverage_pct: @diff_coverage.diff_coverage_pct,
        diff_coverage_threshold: @diff_coverage.threshold,
        diff_coverage_passed: @diff_coverage.passed,
        files: @diff_coverage.files.map do |f|
          {
            path: f.path,
            coverage_pct: f.diff_coverage_pct,
            uncovered: f.uncovered_lines.size,
            not_loaded: f.not_loaded
          }
        end,
        related_test_count: pr_examples.size,
        related_passes: passes,
        related_failures: failures,
        related_total_test_time: total_time.round(2),
        related_total_test_time_formatted: format_duration(total_time),
        related_slowest_tests: slowest,
        pr_paths: pr_paths,
        pr_spec_paths: pr_spec_paths
      }
    end

    def candidate_spec_paths(source_path)
      return [] unless source_path.end_with?(".rb")

      paths = []
      if source_path.start_with?("app/")
        inner = source_path.sub(%r{^app/}, "").sub(/\.rb$/, "")
        paths << "spec/#{inner}_spec.rb"
      elsif source_path.start_with?("lib/")
        inner = source_path.sub(%r{^lib/}, "").sub(/\.rb$/, "")
        paths << "spec/#{inner}_spec.rb"
        paths << "spec/lib/#{inner}_spec.rb"
      end
      paths
    end

    # ── Overall coverage ──

    def overall_coverage
      return nil unless @simplecov

      total = covered = branch_total = branch_covered = 0

      @simplecov.each_value do |data|
        lines = data.is_a?(Hash) ? data["lines"] : data
        t, c = count_coverage(lines)
        total += t
        covered += c

        branches = data.is_a?(Hash) ? data.fetch("branches", {}) : {}
        branches.each_value do |branch_data|
          branch_data.each_value do |count|
            branch_total += 1
            branch_covered += 1 if count > 0
          end
        end
      end

      pct = ->(c, t) { t > 0 ? (c.to_f / t * 100).round(1) : 0.0 }
      {
        total_lines: total, covered_lines: covered, missed_lines: total - covered,
        coverage_pct: pct[covered, total],
        branch_total: branch_total, branch_covered: branch_covered,
        branch_coverage_pct: pct[branch_covered, branch_total]
      }
    end

    def count_coverage(lines_array)
      total = covered = 0
      (lines_array || []).each do |count|
        next if count.nil?
        total += 1
        covered += 1 if count > 0
      end
      [total, covered]
    end

    # ── Per-file coverage ──

    def file_coverage_list
      return [] unless @simplecov

      churn_files = @git_churn&.dig("files") || {}

      @simplecov.map do |abs_path, data|
        lines = data.is_a?(Hash) ? data["lines"] : data
        relative = strip_to_relative(abs_path)

        total, covered = count_coverage(lines)
        cov_pct = total > 0 ? (covered.to_f / total * 100).round(1) : 0.0
        churn = churn_files[relative] || 0
        risk = (churn * (100 - cov_pct)).round(0)

        branches = data.is_a?(Hash) ? data.fetch("branches", {}) : {}
        b_total = b_covered = 0
        branches.each_value do |bd|
          bd.each_value { |c| b_total += 1; b_covered += 1 if c > 0 }
        end
        branch_pct = b_total > 0 ? (b_covered.to_f / b_total * 100).round(1) : nil

        {
          path: relative,
          total_lines: total,
          covered_lines: covered,
          missed_lines: total - covered,
          coverage_pct: cov_pct,
          branch_coverage_pct: branch_pct,
          churn: churn,
          risk_score: risk
        }
      end.sort_by { |f| -f[:risk_score] }
    end

    # ── RSpec summary ──

    def rspec_summary
      return nil unless @rspec

      summary = @rspec["summary"] || {}
      {
        duration_seconds: summary["duration"],
        duration_formatted: format_duration(summary["duration"]),
        example_count: summary["example_count"],
        failure_count: summary["failure_count"],
        pending_count: summary["pending_count"]
      }
    end

    # ── Slowest tests ──

    def slowest_tests
      return [] unless @rspec && @rspec["examples"]

      @rspec["examples"]
        .select { |e| e["run_time"] && e["status"] != "pending" }
        .sort_by { |e| -e["run_time"] }
        .first(20)
        .map { |e| map_test(e) }
    end

    def failed_tests
      return [] unless @rspec && @rspec["examples"]

      @rspec["examples"]
        .select { |e| e["status"] == "failed" }
        .map { |e| map_test(e) }
    end

    def map_test(e)
      exc = e["exception"]
      {
        description: e["full_description"] || e["description"],
        file: "#{e['file_path']}:#{e['line_number']}",
        duration: (e["run_time"] || 0).round(2),
        status: e["status"],
        slow: (e["run_time"] || 0) >= @config.slow_test_threshold,
        exception: exc ? { class: exc["class"], message: exc["message"], backtrace: (exc["backtrace"] || [])[0..7] } : nil
      }
    end

    # ── Time distribution ──

    def test_time_distribution
      return nil unless @rspec && @rspec["examples"]

      buckets = [
        { label: "<0.01s", min: 0, max: 0.01, count: 0, color: "var(--green)" },
        { label: "0.01–0.05s", min: 0.01, max: 0.05, count: 0, color: "var(--green)" },
        { label: "0.05–0.1s", min: 0.05, max: 0.1, count: 0, color: "var(--yellow)" },
        { label: "0.1–0.5s", min: 0.1, max: 0.5, count: 0, color: "var(--yellow)" },
        { label: "0.5–1s", min: 0.5, max: 1.0, count: 0, color: "var(--orange)" },
        { label: ">1s", min: 1.0, max: Float::INFINITY, count: 0, color: "var(--red)" }
      ]

      @rspec["examples"].each do |e|
        t = e["run_time"] || 0
        bucket = buckets.find { |b| t >= b[:min] && t < b[:max] }
        bucket[:count] += 1 if bucket
      end

      max_count = buckets.map { |b| b[:count] }.max
      buckets.each { |b| b[:pct] = max_count > 0 ? (b[:count].to_f / max_count * 100).round(0) : 0 }
      buckets
    end

    # ── Time by file ──

    def time_by_file
      return [] unless @rspec && @rspec["examples"]

      grouped = @rspec["examples"]
        .select { |e| e["run_time"] && e["status"] != "pending" }
        .group_by { |e| e["file_path"] }

      grouped.map do |file, examples|
        total = examples.sum { |e| e["run_time"] || 0 }
        slowest = examples.max_by { |e| e["run_time"] || 0 }
        {
          file: file,
          total_time: total.round(3),
          count: examples.size,
          avg_time: (total / examples.size).round(3),
          slowest_description: slowest&.dig("full_description"),
          slowest_duration: slowest&.dig("run_time")&.round(3)
        }
      end.sort_by { |f| -f[:total_time] }
    end

    # ── Factory health ──

    def factory_health
      return nil unless @factory_prof

      grand_total = @factory_prof["total_count"].to_f
      grand_time = parse_factory_time(@factory_prof["total_time"])

      stats = (@factory_prof["stats"] || []).map do |s|
        cascade_ratio = s["top_level_count"].to_i > 0 ? (s["total_count"].to_f / s["top_level_count"]).round(1) : 0
        dep_per_call = [(cascade_ratio - 1).round(1), 0].max
        time_val = s["total_time"].is_a?(Numeric) ? s["total_time"] : 0
        count_pct = grand_total > 0 ? (s["total_count"].to_f / grand_total * 100).round(1) : 0
        time_pct = grand_time > 0 ? (time_val / grand_time * 100).round(1) : 0
        stub_saves = (s["total_count"] * 0.5).round
        stub_time = (time_val * 0.5).round(1)
        {
          name: s["name"],
          total_count: s["total_count"],
          top_level_count: s["top_level_count"],
          cascade_ratio: cascade_ratio,
          dep_per_call: dep_per_call,
          total_time: s["total_time"],
          top_level_time: s["top_level_time"],
          count_pct: count_pct,
          time_pct: time_pct,
          stub_saves: stub_saves,
          stub_time_saved: stub_time
        }
      end

      {
        total_count: @factory_prof["total_count"],
        total_top_level_count: @factory_prof["total_top_level_count"],
        total_time: @factory_prof["total_time"],
        total_uniq_factories: @factory_prof["total_uniq_factories"],
        stats: stats,
        suggestions: factory_suggestions(stats)
      }
    end

    def factory_suggestions(stats)
      suggestions = []
      stats.each do |s|
        if s[:cascade_ratio] >= 3 && s[:total_count] >= 100
          suggestions << {
            severity: s[:cascade_ratio] >= 5 ? "critical" : "high",
            factory: s[:name],
            message: "`:#{s[:name]}` has cascade ratio #{s[:cascade_ratio]}x " \
                     "(#{s[:total_count]} total / #{s[:top_level_count]} top-level). " \
                     "Consider using `build_stubbed` or traits to reduce unnecessary associations."
          }
        end
        if s[:total_count] >= 500 && s[:cascade_ratio] < 2
          suggestions << {
            severity: "medium",
            factory: s[:name],
            message: "`:#{s[:name]}` is created #{s[:total_count]} times. " \
                     "Consider using `let_it_be` from test-prof to share across examples."
          }
        end
      end
      suggestions
    end

    # ── Risk scores ──

    def risk_scores
      file_coverage_list.select { |f| f[:risk_score] > 0 }
    end

    # ── Insights ──

    def insights
      {
        high_risk: high_risk_files,
        over_tested: over_tested_files,
        false_security: false_security_files,
        untested_hot_paths: untested_hot_paths
      }
    end

    def high_risk_files
      file_coverage_list.select { |f| f[:churn] > 5 && f[:coverage_pct] < 70 }
    end

    def over_tested_files
      return [] unless @rspec && @rspec["examples"]

      file_times = Hash.new(0.0)
      @rspec["examples"].each do |e|
        file_times[e["file_path"]] += (e["run_time"] || 0)
      end

      file_coverage_list.select do |f|
        spec_path = "./spec/#{f[:path].sub('app/', '').sub('.rb', '_spec.rb')}"
        f[:coverage_pct] > 90 && (file_times[spec_path] || 0) > 10
      end.map do |f|
        spec_path = "./spec/#{f[:path].sub('app/', '').sub('.rb', '_spec.rb')}"
        f.merge(total_test_time: (file_times[spec_path] || 0).round(1))
      end
    end

    def false_security_files
      return [] unless @rspec_dissect && @rspec_dissect["suites"]

      @rspec_dissect["suites"].filter_map do |suite|
        before_pct = suite["before_pct"] || 0
        let_pct = suite["let_pct"] || 0
        hook_pct = before_pct + let_pct
        next unless hook_pct > 70

        {
          location: suite["location"],
          description: suite["description"],
          total_time: suite["total_time"],
          hook_time: suite["before_time"],
          example_time: suite["example_time"],
          hook_pct: hook_pct.round(1)
        }
      end
    end

    def untested_hot_paths
      return [] unless @git_churn

      churn_files = @git_churn["files"] || {}
      coverage_map = file_coverage_list.each_with_object({}) { |f, h| h[f[:path]] = f[:coverage_pct] }
      fnm_flags = File::FNM_PATHNAME | File::FNM_EXTGLOB

      churn_files.filter_map do |path, commits|
        # Only flag files that SimpleCov could have tracked. Without this, churned
        # non-Ruby files (locales, schema.rb, migrations, JSON fixtures) show up
        # as "0% coverage" hot paths even though they're not testable code.
        next unless File.fnmatch?(@config.simplecov_track_files, path, fnm_flags)

        cov = coverage_map[path]
        next unless commits > 10 && (cov.nil? || cov < 40)

        { path: path, churn: commits, coverage_pct: cov || 0.0 }
      end.sort_by { |f| -f[:churn] }
    end

    # ── Helpers ──

    def strip_to_relative(abs_path)
      abs_path.sub(%r{^#{Regexp.escape(@config.project_root)}/?}, "")
    end

    def format_duration(seconds)
      return "—" unless seconds

      mins = (seconds / 60).floor
      secs = (seconds % 60).floor
      mins > 0 ? "#{mins}m #{secs}s" : "#{secs}s"
    end

    def parse_factory_time(str)
      return str if str.is_a?(Numeric)
      return 0 unless str.is_a?(String)
      str.sub(/s$/, "").to_f
    end
  end
end
