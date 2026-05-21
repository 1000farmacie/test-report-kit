# frozen_string_literal: true

require "fileutils"
require "time"
require "digest"

module TestReportKit
  class MarkdownExporter
    # GitHub PR/issue comment bodies are capped at 65,536 chars. Stay well below so
    # callers (e.g. CI workflows) can prepend headers / append download links without
    # blowing the limit.
    MAX_BYTES = 60_000

    # Caps for the `## Failing Tests` section. Keeps the comment well under
    # MAX_BYTES even on a heavily-failing suite; full failure list is in HTML.
    MAX_FAILURES_IN_MARKDOWN = 10
    FAILURE_MESSAGE_BYTES = 500

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
        sections << failures_section
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

    # Lists individual failing tests with file:line, description, and exception
    # message. Tests whose spec file maps to a PR-changed source file (per
    # MetricsCalculator#candidate_spec_paths) are prefixed with 🔴 — the same
    # "related" logic used by pr_metrics elsewhere.
    def failures_section
      failures = @metrics[:failed_tests] || []
      return nil if failures.empty?

      pr_spec_paths = @metrics.dig(:pr_metrics, :pr_spec_paths) || []
      shown = failures.first(MAX_FAILURES_IN_MARKDOWN)
      remaining = failures.size - shown.size

      lines = ["## Failing Tests\n"]
      lines << "#{failures.size} test#{'s' unless failures.size == 1} failing in this run."
      lines << ""

      shown.each do |t|
        path, line = split_file_line(t[:file])
        pr_related = pr_spec_paths.include?(path)
        marker = pr_related ? "🔴 " : ""
        related_tag = pr_related ? " — in PR-related file" : ""

        lines << "### #{marker}#{md_link("`#{t[:file]}`", blob_url(path, line: line))}#{related_tag}"
        lines << "**#{t[:description]}**"
        exc = t[:exception]
        if exc
          msg = "#{exc[:class]}:\n#{exc[:message]}"
          msg = "#{msg.byteslice(0, FAILURE_MESSAGE_BYTES)}…" if msg.bytesize > FAILURE_MESSAGE_BYTES
          lines << "```"
          lines << msg
          lines << "```"
        end
        lines << ""
      end

      lines << "_…and #{remaining} more. Full list in the HTML dashboard._" if remaining > 0

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
          file_cell = md_link("`#{f[:path]}`", diff_url(f[:path]))
          lines << "| #{file_cell} | #{pct} | #{f[:uncovered]} |"
        end
      end

      if pr[:related_slowest_tests].any?
        lines << ""
        lines << "### Slowest related tests"
        lines << "| Test | Duration | Status |"
        lines << "|------|----------|--------|"
        pr[:related_slowest_tests].each do |t|
          desc = t[:description].to_s[0..80]
          path, line = split_file_line(t[:file])
          test_cell = md_link(md_cell(desc), blob_url(path, line: line))
          lines << "| #{test_cell} | #{t[:duration]}s | #{t[:status]} |"
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

    def github_base
      @github_base ||= @config.github_url.to_s.chomp("/") # tolerate a trailing slash
    end

    # Blob URL for a repo-relative path at the tested commit, optionally pinned
    # to a line. Same shape as Generator#gh_link. Returns nil when links can't
    # be built so callers degrade to bare text.
    def blob_url(path, line: nil)
      return nil if github_base.empty? || sha.to_s.empty?

      url = "#{github_base}/blob/#{sha}/#{path}"
      line ? "#{url}#L#{line}" : url
    end

    # Per-file anchor on the PR "Files changed" tab: `diff-` + SHA256(new path).
    # Needs the PR number; without it, fall back to the blob view at the tested
    # SHA. If the anchor ever fails to match (e.g. a renamed file), GitHub just
    # lands on /pull/N/files rather than 404ing.
    def diff_url(path)
      return blob_url(path) if github_base.empty? || pr_number.nil?

      "#{github_base}/pull/#{pr_number}/files#diff-#{Digest::SHA256.hexdigest(path)}"
    end

    def md_link(text, url)
      url ? "[#{text}](#{url})" : text
    end

    # RSpec file_path keeps a "./" prefix in some sections (failures) and not in
    # others (slowest) — strip it so the blob path resolves cleanly.
    #   "./spec/foo_spec.rb:10" => ["spec/foo_spec.rb", "10"]
    def split_file_line(ref)
      raw = ref.to_s.sub(%r{\A\./}, "")
      (m = raw.match(/\A(.+):(\d+)\z/)) ? [m[1], m[2]] : [raw, nil]
    end

    # Escape characters that would break a GitHub markdown table cell ("|") or a
    # link's bracketed text ("[", "]").
    def md_cell(text)
      text.to_s.gsub(/[|\[\]]/) { |c| "\\#{c}" }
    end

    def pr_number
      @pr_number ||= (@config.github_pr_number || ENV["TEST_REPORT_PR_NUMBER"]).to_s[/\d+/]
    end
  end
end
