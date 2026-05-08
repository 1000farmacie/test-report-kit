# frozen_string_literal: true

require "spec_helper"
require "test_report_kit/data_loader"
require "tmpdir"
require "fileutils"

RSpec.describe TestReportKit::DataLoader do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) do
    TestReportKit.configure do |c|
      c.project_root = tmpdir
      c.output_dir = File.join(tmpdir, "tmp/test_report")
    end
    TestReportKit.configuration
  end
  let(:loader) { described_class.new(config: config) }

  after { FileUtils.rm_rf(tmpdir) }

  def setup_fixture(relative_path, fixture_name)
    dest = File.join(tmpdir, relative_path)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp(File.join(FIXTURES_PATH, fixture_name), dest)
  end

  describe "#load_all" do
    it "returns self for chaining" do
      expect(loader.load_all).to eq(loader)
    end

    it "sets all data attributes to nil when no files exist" do
      loader.load_all
      expect(loader.simplecov_data).to be_nil
      expect(loader.rspec_data).to be_nil
      expect(loader.factory_prof_data).to be_nil
      expect(loader.event_prof_data).to be_nil
      expect(loader.rspec_dissect_data).to be_nil
      expect(loader.git_churn_data).to be_nil
    end
  end

  describe "SimpleCov loading" do
    before { setup_fixture("coverage/.resultset.json", "simplecov_resultset.json") }

    it "loads and merges SimpleCov data" do
      loader.load_all
      expect(loader.simplecov_data).to be_a(Hash)
      expect(loader.simplecov_data.keys.size).to eq(2)
    end

    it "normalizes coverage to lines/branches hash" do
      loader.load_all
      file_data = loader.simplecov_data.values.first
      expect(file_data).to have_key("lines")
      expect(file_data).to have_key("branches")
      expect(file_data["lines"]).to be_an(Array)
    end

    context "with legacy array format" do
      before do
        legacy = {
          "RSpec" => {
            "coverage" => {
              "/app/models/user.rb" => [1, 0, nil, 1]
            },
            "timestamp" => 12345
          }
        }
        File.write(File.join(tmpdir, "coverage/.resultset.json"), JSON.generate(legacy))
      end

      it "normalizes arrays to lines/branches hash" do
        loader.load_all
        data = loader.simplecov_data["/app/models/user.rb"]
        expect(data["lines"]).to eq([1, 0, nil, 1])
        expect(data["branches"]).to eq({})
      end
    end

    context "with multiple commands" do
      before do
        multi = {
          "RSpec" => {
            "coverage" => { "/app/models/user.rb" => { "lines" => [1, 0, nil], "branches" => {} } },
            "timestamp" => 1
          },
          "Cucumber" => {
            "coverage" => { "/app/models/user.rb" => { "lines" => [0, 1, nil], "branches" => {} } },
            "timestamp" => 2
          }
        }
        File.write(File.join(tmpdir, "coverage/.resultset.json"), JSON.generate(multi))
      end

      it "merges coverage by summing line counts" do
        loader.load_all
        data = loader.simplecov_data["/app/models/user.rb"]
        expect(data["lines"]).to eq([1, 1, nil])
      end
    end
  end

  describe "RSpec results loading" do
    before { setup_fixture("tmp/test_report/rspec_results.json", "rspec_results.json") }

    it "loads RSpec JSON results" do
      loader.load_all
      expect(loader.rspec_data).to be_a(Hash)
      expect(loader.rspec_data["summary"]["example_count"]).to eq(4521)
      expect(loader.rspec_data["examples"]).to be_an(Array)
    end
  end

  describe "FactoryProf loading" do
    before { setup_fixture("tmp/test_report/factory_prof.json", "factory_prof.json") }

    it "loads FactoryProf JSON" do
      loader.load_all
      expect(loader.factory_prof_data).to be_a(Hash)
      expect(loader.factory_prof_data["total_count"]).to eq(15832)
      expect(loader.factory_prof_data["stats"]).to be_an(Array)
      expect(loader.factory_prof_data["stats"].first["name"]).to eq("order")
    end
  end

  describe "EventProf loading" do
    before { setup_fixture("tmp/test_report/event_prof.json", "event_prof.json") }

    it "loads EventProf JSON" do
      loader.load_all
      expect(loader.event_prof_data).to be_a(Hash)
      expect(loader.event_prof_data["event"]).to eq("sql.active_record")
      expect(loader.event_prof_data["total_events"]).to eq(4567)
    end
  end

  describe "RSpecDissect loading" do
    before { setup_fixture("tmp/test_report/rspec_dissect.json", "rspec_dissect.json") }

    it "loads RSpecDissect JSON" do
      loader.load_all
      expect(loader.rspec_dissect_data).to be_a(Hash)
      expect(loader.rspec_dissect_data["suites"]).to be_an(Array)
      expect(loader.rspec_dissect_data["suites"].first["description"]).to eq("UsersController")
    end
  end

  describe "Git churn loading" do
    before { setup_fixture("tmp/test_report/git_churn.json", "git_churn.json") }

    it "loads git churn JSON" do
      loader.load_all
      expect(loader.git_churn_data).to be_a(Hash)
      expect(loader.git_churn_data["files"]).to be_a(Hash)
      expect(loader.git_churn_data["files"]["app/services/cart_optimizer.rb"]).to eq(18)
    end
  end

  describe "error handling" do
    it "returns nil for malformed JSON" do
      dest = File.join(tmpdir, "tmp/test_report/rspec_results.json")
      FileUtils.mkdir_p(File.dirname(dest))
      File.write(dest, "not valid json {{{")

      expect { loader.load_all }.to output(/Failed to parse/).to_stderr
      expect(loader.rspec_data).to be_nil
    end
  end
end
