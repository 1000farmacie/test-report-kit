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

  describe "template link safety" do
    # The hand-written GitHub links interpolated `sha` and `test_file` into an href
    # without escaping, unlike `gh_link`, which escapes the whole URL. `test_file`
    # comes from the RSpec JSON, so a spec filename containing a double quote --
    # which any contributor can create -- closed the attribute and injected an
    # event handler into the report.
    #
    # This is a ratchet, not a grammar: every interpolation that currently sits in
    # an HTML attribute without h() was read and confirmed to yield a fixed palette
    # token (`var(--red)`), a boolean, or a number -- never attacker text. Anything
    # NEW must be looked at by a human and added here deliberately. A static sweep
    # rather than a render assertion because the failure mode is someone writing
    # another link, which must fail regardless of what a fixture happens to render.
    KNOWN_SAFE_ATTRIBUTE_EXPRESSIONS = [
      "bucket[:color]",
      "bucket[:count] > 0 ? '2px' : '0'",
      "bucket[:pct]",
      "coverage_color(diff_cov.diff_coverage_pct)",
      "coverage_color(f.diff_coverage_pct)",
      "coverage_color(f[:coverage_pct])",
      "coverage_color(overall_coverage[:coverage_pct])",
      "diff_cov && diff_cov.passed == false ? 'var(--red)' : 'var(--green)'",
      "f.diff_coverage_pct || 0",
      "f.uncovered_lines.any? ? 'var(--red)' : 'var(--text-muted)'",
      "f.uncovered_lines.size > 10 ? ' font-weight: 700;' : ''",
      "f[:branch_coverage_pct] ? coverage_color(f[:branch_coverage_pct]) : 'var(--text-muted)'",
      "f[:coverage_pct]",
      "f[:hook_pct] >= 70 ? 'var(--red)' : 'var(--yellow)'",
      "f[:hook_pct] >= 70 ? 'var(--red-dim)' : 'var(--yellow-dim)'",
      "in_pr?(f[:path])",
      "in_pr_attr",
      "in_pr_spec?(ep_parts[0])",
      "in_pr_spec?(fp)",
      "in_pr_spec?(loc_p[0])",
      "in_pr_spec?(loc_parts[0])",
      "overall_coverage ? coverage_color(overall_coverage[:coverage_pct]) : 'var(--accent)'",
      "risk_bg(f[:risk_score])",
      "risk_color(f[:risk_score])",
      "s[:cascade_ratio] >= 5 ? 'var(--red)' : s[:cascade_ratio] >= 3 ? 'var(--yellow)' : 'var(--green)'",
      "s[:cascade_ratio] >= 5 ? 'var(--red-dim)' : s[:cascade_ratio] >= 3 ? 'var(--yellow-dim)' : 'var(--green-dim)'",
      "s[:count_pct]",
      "s[:dep_per_call] >= 3 ? 'var(--red)' : s[:dep_per_call] >= 1 ? 'var(--yellow)' : 'var(--green)'",
      "s[:time_pct]",
      "s[:total_count] >= 1000 ? 'var(--red)' : s[:total_count] >= 500 ? 'var(--orange)' : 'var(--text-secondary)'",
      "severity_color(s[:severity])",
      "t[:slow] ? 'var(--red)' : 'var(--yellow)'",
      "t[:status] == 'passed' ? 'pass' : 'fail'",
    ].freeze

    let(:template_dir) { File.expand_path("../../lib/test_report_kit/templates", __dir__) }

    # Any attribute, either quote style -- not just double-quoted href/src. The
    # narrow first version of this sweep missed the JS link builder entirely.
    let(:attribute_interpolations) do
      Dir.glob(File.join(template_dir, "*.erb")).sort.flat_map do |path|
        File.readlines(path).each_with_index.flat_map do |line, idx|
          line.scan(/[\w:-]+=(?:"[^"]*"|'[^']*')/).flat_map do |attr|
            attr.scan(/<%=(.+?)%>/)
                .map { |m| m.first.strip }
                .reject { |expr| expr.start_with?("h(") }
                .map { |expr| { where: "#{File.basename(path)}:#{idx + 1}", expr: expr } }
          end
        end
      end
    end

    it "has no unreviewed interpolation inside an HTML attribute" do
      unreviewed = attribute_interpolations
                   .reject { |i| KNOWN_SAFE_ATTRIBUTE_EXPRESSIONS.include?(i[:expr]) }
                   .map { |i| "#{i[:where]}: #{i[:expr]}" }

      expect(unreviewed).to be_empty
    end

    it "escapes a double quote in a spec path so it cannot close the attribute" do
      escaped = generator.send(:h, 'spec/x" onmouseover="alert(1)')
      expect(escaped).not_to include('"')
      expect(escaped).to include("&quot;")
    end
  end

  describe "coverage viewer JS safety" do
    # The viewer builds the same GitHub link client-side and assigns it via
    # innerHTML. `path` is a repository file path and `covConfig.sha` comes from
    # TEST_REPORT_SHA, so both need escHtml() exactly as the server-rendered links
    # need h(). Neither the attribute ratchet nor a render assertion covers this:
    # it is JS string concatenation, not an ERB attribute.
    let(:dashboard_js) { File.read(File.expand_path("../../lib/test_report_kit/templates/dashboard.html.erb", __dir__)) }
    let(:link_line) { dashboard_js.lines.find { |l| l.include?("cov-line-num") && l.include?("href") } }

    it "escapes every interpolated value in the client-side link" do
      expect(link_line).not_to be_nil

      aggregate_failures do
        expect(link_line).to include("escHtml(covConfig.github_url)")
        expect(link_line).to include("escHtml(covConfig.sha)")
        expect(link_line).to include("escHtml(path)")
        expect(link_line).not_to match(/\+\s*covConfig\.sha\s*\+/)
        expect(link_line).not_to match(/\+\s*path\s*\+/)
      end
    end
  end

  describe "embedded JSON safety" do
    # `to_json` escapes neither `<` nor `/`, so any string reaching a JSON block
    # could emit a literal `</script>` and turn the rest of the document into live
    # markup -- no quote character needed. coverage_file_data_json embeds the full
    # source of every uncovered file, i.e. arbitrary repository content.
    let(:payload) { "</script><img src=x onerror=alert(1)>" }

    it "neutralises a script closer coming from file contents" do
      json = generator.send(:script_safe_json, { "app/evil.rb" => { lines: [payload] } })

      expect(json).not_to match(%r{</script}i)
      expect(JSON.parse(json).dig("app/evil.rb", "lines", 0)).to eq(payload)
    end

    it "routes every embedded JSON block through the escaper" do
      # Matched case-insensitively and without requiring the closing `>`: a parser
      # also ends the element on `</SCRIPT>`, `</script >` and `</script/>`, so an
      # exact-string assertion would pass against a partial defence.
      aggregate_failures do
        %i[json_data coverage_file_data_json coverage_config_json].each do |helper|
          expect(generator.send(helper)).not_to match(%r{</script}i), "#{helper} can close its script element"
        end
      end
    end

    it "neutralises every script-closer variant in the embedded markdown" do
      variants = ["a</SCRIPT>b", "a</script >b", "a</script/>b", "a</script\tb", "a</script\nb", "a</script>b"]

      aggregate_failures do
        variants.each do |variant|
          generator.instance_variable_set(:@markdown_content, variant)
          expect(generator.send(:embedded_markdown)).not_to match(%r{</script}i), "#{variant.inspect} closes the element"
        end
      end
    end
  end
end
