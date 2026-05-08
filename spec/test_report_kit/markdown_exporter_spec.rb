# frozen_string_literal: true

require "spec_helper"
require "test_report_kit/diff_coverage"
require "test_report_kit/markdown_exporter"
require "tmpdir"
require "fileutils"

RSpec.describe TestReportKit::MarkdownExporter do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) do
    TestReportKit.configure do |c|
      c.output_dir = tmpdir
      c.project_name = "test_app"
    end
    TestReportKit.configuration
  end

  let(:metrics) do
    {
      overall_coverage: { total_lines: 100, covered_lines: 70, missed_lines: 30, coverage_pct: 70.0, branch_coverage_pct: 55.0 },
      rspec_summary: { duration_seconds: 10.5, duration_formatted: "10s", example_count: 50, failure_count: 0, pending_count: 2 },
      file_coverage: [
        { path: "app/services/cart.rb", coverage_pct: 45.0, missed_lines: 20, churn: 10, risk_score: 550 },
        { path: "app/models/order.rb", coverage_pct: 90.0, missed_lines: 3, churn: 2, risk_score: 20 }
      ],
      factory_health: { total_count: 500, suggestions: [{ severity: "high", factory: "order", message: "cascade ratio 5x" }] },
      risk_scores: [{ path: "app/services/cart.rb", coverage_pct: 45.0, churn: 10, risk_score: 550 }],
      insights: {
        high_risk: [{ path: "app/services/cart.rb", coverage_pct: 45.0, churn: 10 }],
        untested_hot_paths: [{ path: "app/services/pricing.rb", churn: 15 }],
        over_tested: [], false_security: []
      },
      slowest_tests: [],
      pr_metrics: {
        file_count: 1,
        diff_coverage_pct: 62.5,
        diff_coverage_threshold: 90,
        diff_coverage_passed: false,
        files: [{ path: "app/services/cart.rb", coverage_pct: 33.3, uncovered: 2, not_loaded: false }],
        related_test_count: 4,
        related_passes: 4,
        related_failures: 0,
        related_total_test_time: 1.23,
        related_total_test_time_formatted: "1s",
        related_slowest_tests: [
          { description: "Cart#optimize handles empty", file: "spec/services/cart_spec.rb:10", duration: 0.5, status: "passed", slow: false }
        ],
        pr_paths: ["app/services/cart.rb"],
        pr_spec_paths: ["spec/services/cart_spec.rb"]
      }
    }
  end

  let(:diff_coverage) do
    TestReportKit::DiffCoverage::Result.new(
      base_branch: "main", base_sha: "abc", head_sha: "def",
      total_changed_lines: 10, executable_changed_lines: 8,
      covered_changed_lines: 5, uncovered_changed_lines: 3,
      diff_coverage_pct: 62.5, threshold: 90, passed: false,
      files: [
        TestReportKit::DiffCoverage::FileCoverage.new(
          path: "app/services/cart.rb", changed_lines: [1, 2, 3],
          covered_lines: [1], uncovered_lines: [2, 3], non_executable_lines: [],
          diff_coverage_pct: 33.3, not_loaded: false,
          uncovered_content: [
            { type: :context, line: 1, content: "  def optimize" },
            { type: :uncovered, line: 2, content: "    raise 'error'" },
            { type: :uncovered, line: 3, content: "  end" }
          ]
        )
      ]
    )
  end

  let(:exporter) { described_class.new(metrics: metrics, diff_coverage: diff_coverage, config: config) }

  after { FileUtils.rm_rf(tmpdir) }

  describe "#export" do
    it "creates report.md" do
      path = exporter.export
      expect(File.exist?(path)).to be true
      expect(path).to end_with("report.md")
    end

    it "includes overall stats" do
      exporter.export
      md = File.read(File.join(tmpdir, "report.md"))
      expect(md).to include("## Overall")
      expect(md).to include("70.0%")
      expect(md).to include("50 examples")
    end

    it "includes a 'This PR' section with file count, diff coverage, and related tests" do
      exporter.export
      md = File.read(File.join(tmpdir, "report.md"))
      expect(md).to include("## This PR")
      expect(md).to include("Files changed | 1")
      expect(md).to include("62.5%")
      expect(md).to include("Related tests | 4 examples")
    end

    it "lists files changed in the PR" do
      exporter.export
      md = File.read(File.join(tmpdir, "report.md"))
      expect(md).to include("### Files changed")
      expect(md).to include("`app/services/cart.rb`")
    end

    it "lists slowest related tests when present" do
      exporter.export
      md = File.read(File.join(tmpdir, "report.md"))
      expect(md).to include("### Slowest related tests")
      expect(md).to include("Cart#optimize handles empty")
    end

    it "includes uncovered changes (diff coverage code excerpts)" do
      exporter.export
      md = File.read(File.join(tmpdir, "report.md"))
      expect(md).to include("## Uncovered Changes")
      expect(md).to include("cart.rb")
      expect(md).to include("raise 'error'")
    end

    it "includes action items focused on the PR" do
      exporter.export
      md = File.read(File.join(tmpdir, "report.md"))
      expect(md).to include("## Action Items")
      expect(md).to include("Diff coverage below threshold")
      # Global insights (high_risk, untested_hot_paths) are no longer in the comment
      expect(md).not_to include("Untested hot path")
      expect(md).not_to include("High-risk")
    end

    it "no longer lists global low-coverage files (kept in HTML report only)" do
      exporter.export
      md = File.read(File.join(tmpdir, "report.md"))
      expect(md).not_to include("Below 80%")
      # The 90% file is not under any section
      expect(md).not_to include("| `app/models/order.rb`")
    end

    context "when there is no diff coverage (e.g. running on main)" do
      let(:diff_coverage) { nil }
      let(:metrics) { super().merge(pr_metrics: nil) }

      it "still produces overall metrics, no PR section" do
        exporter.export
        md = File.read(File.join(tmpdir, "report.md"))
        expect(md).to include("## Overall")
        expect(md).not_to include("## This PR")
      end
    end
  end
end
