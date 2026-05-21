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

    context "with github_url and github_pr_number configured" do
      let(:config) do
        TestReportKit.configure do |c|
          c.output_dir = tmpdir
          c.project_name = "test_app"
          c.github_url = "https://github.com/acme/widgets"
          c.github_pr_number = 123
        end
        TestReportKit.configuration
      end

      before { allow(exporter).to receive(:sha).and_return("deadbee") }

      it "links each section to GitHub", :aggregate_failures do
        exporter.export
        md = File.read(File.join(tmpdir, "report.md"))

        # Files changed -> per-file diff anchor on the PR "Files changed" tab.
        diff_anchor = Digest::SHA256.hexdigest("app/services/cart.rb")
        expect(md).to include("[`app/services/cart.rb`](https://github.com/acme/widgets/pull/123/files#diff-#{diff_anchor})")

        # Slowest related test -> spec source at the exact line, on the tested SHA.
        expect(md).to include("[Cart#optimize handles empty](https://github.com/acme/widgets/blob/deadbee/spec/services/cart_spec.rb#L10)")
      end

      context "with failing tests carrying a ./ prefix" do
        let(:metrics) do
          super().merge(failed_tests: [
                          {
                            description: "Cart#optimize handles empty cart",
                            file: "./spec/services/cart_spec.rb:42",
                            duration: 0.12, status: "failed", slow: false,
                            exception: { class: "RSpec::Expectations::ExpectationNotMetError", message: "boom", backtrace: [] }
                          }
                        ])
        end

        it "links the failing-test header to the line, stripping the ./ prefix", :aggregate_failures do
          exporter.export
          md = File.read(File.join(tmpdir, "report.md"))

          expect(md).to include("[`./spec/services/cart_spec.rb:42`](https://github.com/acme/widgets/blob/deadbee/spec/services/cart_spec.rb#L42)")
          expect(md).not_to include("/blob/deadbee/./spec")
        end
      end
    end

    context "with github_url but no PR number" do
      let(:config) do
        TestReportKit.configure do |c|
          c.output_dir = tmpdir
          c.project_name = "test_app"
          c.github_url = "https://github.com/acme/widgets/" # trailing slash on purpose
        end
        TestReportKit.configuration
      end

      before { allow(exporter).to receive(:sha).and_return("deadbee") }

      it "falls back to a blob link for files changed, no double slash", :aggregate_failures do
        exporter.export
        md = File.read(File.join(tmpdir, "report.md"))

        expect(md).to include("[`app/services/cart.rb`](https://github.com/acme/widgets/blob/deadbee/app/services/cart.rb)")
        expect(md).not_to include("/pull/")
        expect(md).not_to include("widgets//blob")
      end
    end

    context "when a test description contains table-breaking characters" do
      let(:metrics) do
        super().merge(pr_metrics: super()[:pr_metrics].merge(
          related_slowest_tests: [
            { description: "renders [admin] | when piped", file: "spec/services/cart_spec.rb:10", duration: 0.5, status: "passed", slow: false }
          ]
        ))
      end

      it "escapes | [ ] so the table and link stay intact" do
        exporter.export
        md = File.read(File.join(tmpdir, "report.md"))
        expect(md).to include('renders \[admin\] \| when piped')
      end
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

    context "when there are failing tests" do
      let(:pr_related_failure) do
        {
          description: "Cart#optimize handles empty cart",
          file: "./spec/services/cart_spec.rb:42",
          duration: 0.12,
          status: "failed",
          slow: false,
          exception: {
            class: "RSpec::Expectations::ExpectationNotMetError",
            message: "expected: 0\n     got: 1",
            backtrace: []
          }
        }
      end

      let(:unrelated_failure) do
        {
          description: "weird helper does the thing",
          file: "./spec/helpers/weird_helper_spec.rb:7",
          duration: 0.04,
          status: "failed",
          slow: false,
          exception: {
            class: "NoMethodError",
            message: "undefined method `bar' for nil:NilClass",
            backtrace: []
          }
        }
      end

      let(:metrics) { super().merge(failed_tests: [pr_related_failure, unrelated_failure]) }

      it "emits a Failing Tests section with each failure", :aggregate_failures do
        exporter.export
        md = File.read(File.join(tmpdir, "report.md"))

        expect(md).to include("## Failing Tests")
        expect(md).to include("2 tests failing in this run.")
        expect(md).to include("Cart#optimize handles empty cart")
        expect(md).to include("`./spec/services/cart_spec.rb:42`")
        expect(md).to include("RSpec::Expectations::ExpectationNotMetError")
        expect(md).to include("expected: 0")
      end

      it "marks PR-related failures with 🔴 and a tag", :aggregate_failures do
        exporter.export
        md = File.read(File.join(tmpdir, "report.md"))

        expect(md).to include("### 🔴 `./spec/services/cart_spec.rb:42` — in PR-related file")
        expect(md).to include("### `./spec/helpers/weird_helper_spec.rb:7`")
        expect(md).not_to include("🔴 `./spec/helpers/weird_helper_spec.rb")
      end

      context "with more than MAX_FAILURES_IN_MARKDOWN failures" do
        let(:many_failures) do
          (1..15).map do |i|
            {
              description: "spec number #{i}",
              file: "./spec/foo_spec.rb:#{i}",
              duration: 0.01,
              status: "failed",
              slow: false,
              exception: { class: "RuntimeError", message: "boom #{i}", backtrace: [] }
            }
          end
        end
        let(:metrics) { super().merge(failed_tests: many_failures) }

        it "caps the rendered list and shows a remainder footer", :aggregate_failures do
          exporter.export
          md = File.read(File.join(tmpdir, "report.md"))

          expect(md).to include("15 tests failing in this run.")
          expect(md).to include("spec number 1")
          expect(md).to include("spec number 10")
          expect(md).not_to include("spec number 11")
          expect(md).to include("…and 5 more. Full list in the HTML dashboard._")
        end
      end
    end

    context "when there are no failing tests" do
      let(:metrics) { super().merge(failed_tests: []) }

      it "omits the Failing Tests section entirely" do
        exporter.export
        md = File.read(File.join(tmpdir, "report.md"))
        expect(md).not_to include("## Failing Tests")
      end
    end
  end
end
