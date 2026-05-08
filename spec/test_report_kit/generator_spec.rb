# frozen_string_literal: true

require "spec_helper"
require "test_report_kit/data_loader"
require "test_report_kit/diff_coverage"
require "test_report_kit/metrics_calculator"
require "test_report_kit/generator"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe TestReportKit::Generator do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) do
    TestReportKit.configure do |c|
      c.project_root = "/app"
      c.output_dir = tmpdir
      c.project_name = "test_app"
    end
    TestReportKit.configuration
  end

  let(:simplecov_data) do
    {
      "/app/app/services/cart_optimizer.rb" => {
        "lines" => [1, 1, nil, 1, 0, 0, nil, nil, nil, 1],
        "branches" => {}
      },
      "/app/app/models/order.rb" => {
        "lines" => [1, 1, 1, nil, 1, 0, 0, nil, 1, nil],
        "branches" => {}
      }
    }
  end

  let(:rspec_data) { JSON.parse(File.read(File.join(FIXTURES_PATH, "rspec_results.json"))) }
  let(:factory_prof_data) { JSON.parse(File.read(File.join(FIXTURES_PATH, "factory_prof.json"))) }
  let(:event_prof_data) { JSON.parse(File.read(File.join(FIXTURES_PATH, "event_prof.json"))) }
  let(:rspec_dissect_data) { JSON.parse(File.read(File.join(FIXTURES_PATH, "rspec_dissect.json"))) }
  let(:git_churn_data) { JSON.parse(File.read(File.join(FIXTURES_PATH, "git_churn.json"))) }

  let(:diff_coverage) do
    TestReportKit::DiffCoverage::Result.new(
      base_branch: "main", base_sha: "abc1234", head_sha: "def5678",
      total_changed_lines: 15, executable_changed_lines: 12,
      covered_changed_lines: 8, uncovered_changed_lines: 4,
      diff_coverage_pct: 66.7, threshold: 90, passed: false,
      files: [
        TestReportKit::DiffCoverage::FileCoverage.new(
          path: "app/services/cart_optimizer.rb",
          changed_lines: [4, 5, 6, 14],
          covered_lines: [4, 6, 14],
          uncovered_lines: [5],
          non_executable_lines: [],
          diff_coverage_pct: 75.0,
          not_loaded: false,
          uncovered_content: [
            { type: :context, line: 4, content: "  def optimize_cart(cart)" },
            { type: :uncovered, line: 5, content: '    raise CartOptimizationError, "no pharmacies"' },
            { type: :context, line: 6, content: "    select_best_pharmacy(cart)" }
          ]
        ),
        TestReportKit::DiffCoverage::FileCoverage.new(
          path: "app/services/pricing_engine.rb",
          changed_lines: [1, 2, 3, 4, 5],
          covered_lines: [],
          uncovered_lines: [1, 2, 3, 4, 5],
          non_executable_lines: [],
          diff_coverage_pct: 0.0,
          not_loaded: true,
          uncovered_content: []
        )
      ]
    )
  end

  let(:data_loader) do
    loader = TestReportKit::DataLoader.new(config: config)
    allow(loader).to receive(:simplecov_data).and_return(simplecov_data)
    allow(loader).to receive(:rspec_data).and_return(rspec_data)
    allow(loader).to receive(:factory_prof_data).and_return(factory_prof_data)
    allow(loader).to receive(:event_prof_data).and_return(event_prof_data)
    allow(loader).to receive(:rspec_dissect_data).and_return(rspec_dissect_data)
    allow(loader).to receive(:git_churn_data).and_return(git_churn_data)
    loader
  end

  let(:metrics) do
    TestReportKit::MetricsCalculator.new(
      simplecov_data: simplecov_data,
      rspec_data: rspec_data,
      factory_prof_data: factory_prof_data,
      event_prof_data: event_prof_data,
      rspec_dissect_data: rspec_dissect_data,
      git_churn_data: git_churn_data,
      diff_coverage: diff_coverage,
      config: config
    ).call
  end

  let(:generator) do
    described_class.new(
      metrics: metrics,
      diff_coverage: diff_coverage,
      data_loader: data_loader,
      config: config
    )
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe "#generate" do
    let(:html) { generator.generate; File.read(File.join(tmpdir, "index.html")) }

    it "creates index.html in output directory" do
      path = generator.generate
      expect(File.exist?(path)).to be true
      expect(path).to end_with("index.html")
    end

    it "produces valid HTML with doctype" do
      expect(html).to start_with("<!DOCTYPE html>")
      expect(html).to include("</html>")
    end

    it "includes the project name" do
      expect(html).to include("test_app")
    end

    it "includes all five tabs" do
      expect(html).to include('data-tab="diff"')
      expect(html).to include('data-tab="coverage"')
      expect(html).to include('data-tab="performance"')
      expect(html).to include('data-tab="factories"')
      expect(html).to include('data-tab="insights"')
    end

    it "includes diff coverage data" do
      expect(html).to include("66.7%")
      expect(html).to include("cart_optimizer.rb")
      expect(html).to include("pricing_engine.rb")
      expect(html).to include("not loaded by tests")
    end

    it "includes coverage table" do
      expect(html).to include("File Coverage Breakdown")
    end

    it "includes slowest tests" do
      expect(html).to include("payment capture timeout")
      expect(html).to include("12.41s")
    end

    it "includes factory data" do
      expect(html).to include("Factory Usage Ranking")
      expect(html).to include(":order")
    end

    it "includes insights" do
      expect(html).to include("High-Risk Files")
      expect(html).to include("Untested Hot Paths")
    end

    it "embeds JSON data for client-side features" do
      expect(html).to include('id="report-data"')
      expect(html).to include("application/json")
    end

    it "includes inline CSS" do
      expect(html).to include("--bg-deep: #0b0e14")
      expect(html).to include("JetBrains Mono")
    end

    it "includes inline JavaScript" do
      expect(html).to include("addEventListener")
      expect(html).to include("table-filter")
    end
  end

  describe "with nil diff coverage" do
    let(:diff_coverage) { nil }

    it "shows empty state for diff tab" do
      html = generator.generate && File.read(File.join(tmpdir, "index.html"))
      expect(html).to include("Diff coverage is not available")
    end
  end

  describe "with nil factory data" do
    let(:factory_prof_data) { nil }

    it "shows empty state for factories tab" do
      html = generator.generate && File.read(File.join(tmpdir, "index.html"))
      expect(html).to include("No factory profiling data available")
    end
  end
end
