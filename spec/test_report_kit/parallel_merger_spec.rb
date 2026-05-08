# frozen_string_literal: true

require "spec_helper"
require "test_report_kit/parallel_merger"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe TestReportKit::ParallelMerger do
  let(:tmpdir) { Dir.mktmpdir }
  let(:node0_dir) { File.join(tmpdir, "test-results-0") }
  let(:node1_dir) { File.join(tmpdir, "test-results-1") }
  let(:config) do
    TestReportKit.configure do |c|
      c.project_root = tmpdir
      c.output_dir = File.join(tmpdir, "tmp/test_report")
    end
    TestReportKit.configuration
  end

  let(:merger) { described_class.new(artifact_dirs: [node0_dir, node1_dir], config: config) }

  before do
    # Create node directories with test data
    [node0_dir, node1_dir].each do |dir|
      FileUtils.mkdir_p(dir)
      FileUtils.mkdir_p(File.join(dir, "coverage"))
    end

    # Node 0: rspec results
    File.write(File.join(node0_dir, "rspec_results.json"), JSON.generate({
      "examples" => [
        { "full_description" => "Test A", "file_path" => "./spec/models/a_spec.rb", "line_number" => 5, "run_time" => 0.5, "status" => "passed" },
        { "full_description" => "Test B", "file_path" => "./spec/models/b_spec.rb", "line_number" => 10, "run_time" => 1.2, "status" => "passed" }
      ],
      "summary" => { "duration" => 1.7, "example_count" => 2, "failure_count" => 0, "pending_count" => 0 }
    }))

    # Node 1: rspec results
    File.write(File.join(node1_dir, "rspec_results.json"), JSON.generate({
      "examples" => [
        { "full_description" => "Test C", "file_path" => "./spec/services/c_spec.rb", "line_number" => 3, "run_time" => 0.8, "status" => "passed" },
        { "full_description" => "Test D", "file_path" => "./spec/services/d_spec.rb", "line_number" => 7, "run_time" => 0.3, "status" => "failed",
          "exception" => { "class" => "RSpec::Expectations::ExpectationNotMetError", "message" => "expected 1, got 2" } }
      ],
      "summary" => { "duration" => 1.1, "example_count" => 2, "failure_count" => 1, "pending_count" => 0 }
    }))

    # Node 0: SimpleCov
    File.write(File.join(node0_dir, "coverage", ".resultset.json"), JSON.generate({
      "RSpec-0" => { "coverage" => { "/app/models/a.rb" => { "lines" => [1, 1, nil, 0] } }, "timestamp" => 1 }
    }))

    # Node 1: SimpleCov
    File.write(File.join(node1_dir, "coverage", ".resultset.json"), JSON.generate({
      "RSpec-1" => { "coverage" => { "/app/services/c.rb" => { "lines" => [1, 0, 1] } }, "timestamp" => 2 }
    }))

    # Node 0: factory_prof
    File.write(File.join(node0_dir, "factory_prof.json"), JSON.generate({
      "total_count" => 30, "total_top_level_count" => 20, "total_time" => "1.5s",
      "stats" => [{ "name" => "user", "total_count" => 20, "top_level_count" => 15, "total_time" => 0.8 }]
    }))

    # Node 1: factory_prof
    File.write(File.join(node1_dir, "factory_prof.json"), JSON.generate({
      "total_count" => 25, "total_top_level_count" => 18, "total_time" => "1.2s",
      "stats" => [{ "name" => "user", "total_count" => 15, "top_level_count" => 10, "total_time" => 0.5 },
                  { "name" => "order", "total_count" => 10, "top_level_count" => 8, "total_time" => 0.7 }]
    }))

    # Resource usage
    File.write(File.join(node0_dir, "resource_usage.json"), JSON.generate({ "peak_memory_mb" => 100, "cpu_user_seconds" => 1.5, "cpu_system_seconds" => 0.2 }))
    File.write(File.join(node1_dir, "resource_usage.json"), JSON.generate({ "peak_memory_mb" => 120, "cpu_user_seconds" => 1.2, "cpu_system_seconds" => 0.3 }))
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe "#merge!" do
    before { merger.merge! }

    it "merges RSpec results" do
      data = JSON.parse(File.read(File.join(config.output_dir, "rspec_results.json")))
      expect(data["examples"].size).to eq(4)
      expect(data["summary"]["example_count"]).to eq(4)
      expect(data["summary"]["failure_count"]).to eq(1)
      expect(data["summary"]["duration"]).to be_within(0.01).of(2.8)
    end

    it "tags examples with node identifier" do
      data = JSON.parse(File.read(File.join(config.output_dir, "rspec_results.json")))
      nodes = data["examples"].map { |e| e["_node"] }.uniq
      expect(nodes.size).to eq(2)
    end

    it "merges SimpleCov coverage" do
      data = JSON.parse(File.read(File.join(tmpdir, "coverage", ".resultset.json")))
      expect(data.keys.size).to eq(2)
      expect(data.keys).to include("RSpec-0-node0", "RSpec-1-node1")
    end

    it "merges FactoryProf stats by factory name" do
      data = JSON.parse(File.read(File.join(config.output_dir, "factory_prof.json")))
      expect(data["total_count"]).to eq(55)
      user = data["stats"].find { |s| s["name"] == "user" }
      expect(user["total_count"]).to eq(35) # 20 + 15
      order = data["stats"].find { |s| s["name"] == "order" }
      expect(order["total_count"]).to eq(10)
    end

    it "merges resource usage (max memory, sum CPU)" do
      data = JSON.parse(File.read(File.join(config.output_dir, "resource_usage.json")))
      expect(data["peak_memory_mb"]).to eq(120) # max of 100, 120
      expect(data["cpu_user_seconds"]).to eq(2.7) # 1.5 + 1.2
    end

    it "generates parallel_info.json" do
      data = JSON.parse(File.read(File.join(config.output_dir, "parallel_info.json")))
      expect(data["node_count"]).to eq(2)
      expect(data["nodes"].size).to eq(2)
      expect(data["nodes"].first["examples"]).to be_a(Integer)
      expect(data["efficiency"]).to be_a(Numeric)
    end
  end
end
