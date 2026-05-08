# frozen_string_literal: true

require "spec_helper"
require "test_report_kit/diff_coverage"
require "test_report_kit/summary_exporter"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe TestReportKit::SummaryExporter do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) do
    TestReportKit.configure do |c|
      c.output_dir = tmpdir
      c.diff_coverage_threshold = 90
    end
    TestReportKit.configuration
  end

  let(:metrics) do
    {
      overall_coverage: {
        total_lines: 1000,
        covered_lines: 785,
        missed_lines: 215,
        coverage_pct: 78.5,
        branch_coverage_pct: 65.3
      },
      rspec_summary: {
        duration_seconds: 342.7,
        duration_formatted: "5m 42s",
        example_count: 4521,
        failure_count: 0,
        pending_count: 23
      },
      slowest_tests: [
        { description: "Order#process handles timeout", file: "spec/models/order_spec.rb:342", duration: 12.41 },
        { description: "CartOptimizer selects pharmacy", file: "spec/services/cart_optimizer_spec.rb:187", duration: 9.83 }
      ],
      factory_health: { total_count: 15832 },
      risk_scores: [
        { path: "app/services/cart_optimizer.rb", coverage_pct: 45.2, churn: 18 },
        { path: "app/models/order.rb", coverage_pct: 62.1, churn: 14 }
      ]
    }
  end

  let(:diff_coverage) do
    TestReportKit::DiffCoverage::Result.new(
      base_branch: "main", base_sha: "abc1234", head_sha: "def5678",
      total_changed_lines: 142, executable_changed_lines: 118,
      covered_changed_lines: 97, uncovered_changed_lines: 21,
      diff_coverage_pct: 82.2, threshold: 90, passed: false,
      files: [
        TestReportKit::DiffCoverage::FileCoverage.new(
          path: "app/services/cart_optimizer.rb",
          changed_lines: [45, 46, 47], covered_lines: [45, 46],
          uncovered_lines: [47], non_executable_lines: [],
          diff_coverage_pct: 66.7, not_loaded: false, uncovered_content: []
        )
      ]
    )
  end

  let(:exporter) { described_class.new(metrics: metrics, diff_coverage: diff_coverage, config: config) }

  after { FileUtils.rm_rf(tmpdir) }

  describe "#export" do
    it "creates summary.json" do
      path = exporter.export
      expect(File.exist?(path)).to be true
      expect(path).to end_with("summary.json")
    end

    it "outputs valid JSON with expected fields" do
      exporter.export
      summary = JSON.parse(File.read(File.join(tmpdir, "summary.json")))

      expect(summary["coverage_pct"]).to eq(78.5)
      expect(summary["branch_coverage_pct"]).to eq(65.3)
      expect(summary["diff_coverage_pct"]).to eq(82.2)
      expect(summary["diff_coverage_passed"]).to be false
      expect(summary["diff_coverage_threshold"]).to eq(90)
      expect(summary["duration_seconds"]).to eq(342.7)
      expect(summary["duration_formatted"]).to eq("5m 42s")
      expect(summary["total_examples"]).to eq(4521)
      expect(summary["total_factory_creates"]).to eq(15832)
      expect(summary["slowest_test_name"]).to include("timeout")
      expect(summary["slowest_test_duration"]).to eq(12.41)
      expect(summary["top_risks"]).to be_an(Array)
      expect(summary["generated_at"]).to be_a(String)
    end

    it "includes diff uncovered files" do
      exporter.export
      summary = JSON.parse(File.read(File.join(tmpdir, "summary.json")))

      uncovered = summary["diff_uncovered_files"]
      expect(uncovered.size).to eq(1)
      expect(uncovered.first["file"]).to eq("app/services/cart_optimizer.rb")
      expect(uncovered.first["uncovered_count"]).to eq(1)
    end

    it "saves previous summary for delta computation" do
      exporter.export
      exporter.export # run twice

      expect(File.exist?(File.join(tmpdir, "previous_summary.json"))).to be true
    end

    it "computes coverage delta from previous run" do
      # First run
      exporter.export

      # Modify coverage for second run
      metrics[:overall_coverage][:coverage_pct] = 80.0
      exporter2 = described_class.new(metrics: metrics, diff_coverage: diff_coverage, config: config)
      exporter2.export

      summary = JSON.parse(File.read(File.join(tmpdir, "summary.json")))
      expect(summary["coverage_delta"]).to eq("+1.5")
    end
  end

  describe "with nil diff coverage" do
    let(:diff_coverage) { nil }

    it "handles nil diff coverage gracefully" do
      exporter.export
      summary = JSON.parse(File.read(File.join(tmpdir, "summary.json")))
      expect(summary["diff_coverage_pct"]).to be_nil
      expect(summary["diff_uncovered_files"]).to eq([])
    end
  end
end
