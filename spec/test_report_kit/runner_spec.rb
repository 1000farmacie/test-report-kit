# frozen_string_literal: true

require "spec_helper"
require "test_report_kit/runner"
require "tmpdir"
require "fileutils"

RSpec.describe TestReportKit::Runner do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) do
    TestReportKit.configure do |c|
      c.project_root = tmpdir
      c.output_dir = File.join(tmpdir, "tmp/test_report")
    end
    TestReportKit.configuration
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe "#run! with :generate mode" do
    let(:runner) { described_class.new(config, mode: :generate) }

    before do
      # Set up fixture data in the expected locations
      output_dir = config.output_dir
      FileUtils.mkdir_p(output_dir)
      FileUtils.mkdir_p(File.join(tmpdir, "coverage"))

      FileUtils.cp(File.join(FIXTURES_PATH, "simplecov_resultset.json"),
                    File.join(tmpdir, "coverage/.resultset.json"))
      FileUtils.cp(File.join(FIXTURES_PATH, "rspec_results.json"),
                    File.join(output_dir, "rspec_results.json"))
      FileUtils.cp(File.join(FIXTURES_PATH, "factory_prof.json"),
                    File.join(output_dir, "factory_prof.json"))
      FileUtils.cp(File.join(FIXTURES_PATH, "event_prof.json"),
                    File.join(output_dir, "event_prof.json"))
      FileUtils.cp(File.join(FIXTURES_PATH, "rspec_dissect.json"),
                    File.join(output_dir, "rspec_dissect.json"))
      FileUtils.cp(File.join(FIXTURES_PATH, "git_churn.json"),
                    File.join(output_dir, "git_churn.json"))
    end

    it "generates report from existing files" do
      exit_code = runner.run!
      expect(exit_code).to eq(0)
      expect(File.exist?(File.join(config.output_dir, "index.html"))).to be true
      expect(File.exist?(File.join(config.output_dir, "summary.json"))).to be true
    end

    it "produces valid HTML" do
      runner.run!
      html = File.read(File.join(config.output_dir, "index.html"))
      expect(html).to include("<!DOCTYPE html>")
      expect(html).to include("Diff Coverage")
      expect(html).to include("Coverage")
    end

    it "produces valid summary JSON" do
      runner.run!
      summary = JSON.parse(File.read(File.join(config.output_dir, "summary.json")))
      expect(summary).to have_key("coverage_pct")
      expect(summary).to have_key("diff_coverage_pct")
      expect(summary).to have_key("generated_at")
    end
  end

  describe "#run! with unknown mode" do
    it "raises an error" do
      runner = described_class.new(config, mode: :unknown)
      expect { runner.run! }.to raise_error(TestReportKit::Error, /Unknown mode/)
    end
  end

  describe "split_profiler_output" do
    let(:runner) { described_class.new(config, mode: :generate) }

    it "extracts EventProf section from log" do
      log_path = File.join(tmpdir, "test_output.log")
      FileUtils.mkdir_p(config.output_dir)
      File.write(log_path, <<~LOG)
        Running tests...
        ..........

        EventProf results for sql.active_record

        Total time: 00:15.234 of 01:30.000 (16.93%)
        Total events: 4567

        Finished in 90 seconds
      LOG

      runner.send(:split_profiler_output, log_path)
      output = File.join(config.output_dir, "event_prof_output.txt")
      expect(File.exist?(output)).to be true
      expect(File.read(output)).to include("EventProf results")
    end

    it "splits sections when test-prof prefixes them with [TEST PROF INFO]" do
      log_path = File.join(tmpdir, "test_output.log")
      FileUtils.mkdir_p(config.output_dir)
      File.write(log_path, <<~LOG)
        Running tests...
        ..........

        [TEST PROF INFO] RSpecDissect report

        Total time: 00:19.899

        Total `let` time: 00:15.935
        Total `before(:each)` time: 00:06.058

        Top 5 slowest suites (by `let` time):

        CartSerializer (./spec/serializers/cart_serializer_spec.rb:3) - 00:09.380 of 00:09.640 (55)

        [TEST PROF INFO] EventProf results for factory.create

        Total time: 00:10.744 of 00:21.617 (49.71%)
        Total events: 861

        Top 5 slowest suites (by time):

        CartSerializer (./spec/serializers/cart_serializer_spec.rb:3) - 00:05.319 (495 / 55) of 00:09.946 (53.49%)

        Finished in 21.86 seconds
      LOG

      runner.send(:split_profiler_output, log_path)
      dissect = File.read(File.join(config.output_dir, "rspec_dissect_output.txt"))
      event_prof = File.read(File.join(config.output_dir, "event_prof_output.txt"))

      expect(dissect).to include("RSpecDissect report")
      expect(dissect).not_to include("EventProf results")
      expect(event_prof).to include("EventProf results for factory.create")
      expect(event_prof).not_to include("Finished in 21.86")
    end
  end

  describe "parse_event_prof_text" do
    let(:runner) { described_class.new(config, mode: :generate) }

    it "parses suites without bleeding the header into the first capture" do
      FileUtils.mkdir_p(config.output_dir)
      text_path = File.join(config.output_dir, "event_prof_output.txt")
      File.write(text_path, <<~TEXT)
        EventProf results for factory.create

        Total time: 00:10.744 of 00:21.617 (49.71%)
        Total events: 861

        Top 5 slowest suites (by time):

        CartSerializer (./spec/serializers/cart_serializer_spec.rb:3) - 00:05.319 (495 / 55) of 00:09.946 (53.49%)
        OrderSerializer (./spec/serializers/order_serializer_spec.rb:3) - 00:00.599 (53 / 18) of 00:01.243 (48.20%)
      TEXT

      runner.send(:parse_event_prof_text, text_path)
      result = JSON.parse(File.read(File.join(config.output_dir, "event_prof.json")))

      expect(result["event"]).to eq("factory.create")
      expect(result["total_events"]).to eq(861)
      expect(result["suites"].size).to eq(2)
      expect(result["suites"].first).to include(
        "description" => "CartSerializer",
        "location" => "./spec/serializers/cart_serializer_spec.rb:3",
        "event_count" => 495,
        "example_count" => 55
      )
      expect(result["suites"].first["description"]).not_to include("EventProf results")
    end
  end

  describe "parse_rspec_dissect_text" do
    let(:runner) { described_class.new(config, mode: :generate) }

    it "parses suites in the modern test-prof format (no percentage between time and 'of')" do
      FileUtils.mkdir_p(config.output_dir)
      text_path = File.join(config.output_dir, "rspec_dissect_output.txt")
      File.write(text_path, <<~TEXT)
        RSpecDissect report

        Total time: 00:19.899

        Total `let` time: 00:15.935
        Total `before(:each)` time: 00:06.058

        Top 5 slowest suites (by `let` time):

        CartSerializer (./spec/serializers/cart_serializer_spec.rb:3) - 00:09.380 of 00:09.640 (55)
        OrderSerializer (./spec/serializers/order_serializer_spec.rb:3) - 00:01.069 of 00:01.147 (18)

        Top 5 slowest suites (by `before(:each)` time):

        CategoryPageSerializer (./spec/serializers/category_page_serializer_spec.rb:3) - 00:01.887 of 00:02.045 (4)
        CartSerializer (./spec/serializers/cart_serializer_spec.rb:3) - 00:01.437 of 00:09.640 (55)
      TEXT

      runner.send(:parse_rspec_dissect_text, text_path)
      result = JSON.parse(File.read(File.join(config.output_dir, "rspec_dissect.json")))

      expect(result["total_time"]).to eq("00:19.899")
      expect(result["suites"].size).to eq(3)

      cart = result["suites"].find { |s| s["description"] == "CartSerializer" }
      expect(cart).to include(
        "location" => "./spec/serializers/cart_serializer_spec.rb:3",
        "total_time" => "00:09.640",
        "example_count" => 55
      )
      # Same suite appears under both "by `let`" (00:09.380) and "by `before(:each)`" (00:01.437);
      # we keep the larger reading.
      expect(cart["before_time"]).to eq("00:09.380")
    end
  end

  describe "setup_simplecov detection" do
    let(:runner) { described_class.new(config, mode: :coverage) }

    it "uses host SimpleCov when spec/spec_helper.rb starts SimpleCov unconditionally" do
      FileUtils.mkdir_p(File.join(tmpdir, "spec"))
      File.write(File.join(tmpdir, "spec/spec_helper.rb"), "SimpleCov.start 'rails'\n")

      expect { runner.send(:setup_simplecov) }
        .to output(/Using existing SimpleCov configuration from spec\/spec_helper\.rb/).to_stdout

      expect(runner.instance_variable_get(:@simplecov_init_path)).to be_nil
    end

    it "ignores SimpleCov in spec/rails_helper.rb (commonly gated on ENV['CI'])" do
      FileUtils.mkdir_p(File.join(tmpdir, "spec"))
      File.write(
        File.join(tmpdir, "spec/rails_helper.rb"),
        "if ENV['CI']\n  require 'simplecov'\n  SimpleCov.start 'rails'\nend\n"
      )

      expect { runner.send(:setup_simplecov) }
        .to output(/Generated SimpleCov configuration/).to_stdout

      expect(runner.instance_variable_get(:@simplecov_init_path)).not_to be_nil
    end

    it "generates an init file when no host SimpleCov is configured" do
      expect { runner.send(:setup_simplecov) }
        .to output(/Generated SimpleCov configuration/).to_stdout

      init_path = runner.instance_variable_get(:@simplecov_init_path)
      expect(init_path).not_to be_nil
      content = File.read(init_path)
      expect(content).to include("SimpleCov.start 'rails'")
      expect(content).not_to include("minimum_coverage ")
    end
  end
end
