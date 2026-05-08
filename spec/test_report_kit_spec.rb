# frozen_string_literal: true

RSpec.describe TestReportKit do
  it "has a version number" do
    expect(TestReportKit::VERSION).to eq("0.1.0")
  end

  describe ".configuration" do
    it "returns a Configuration instance" do
      expect(TestReportKit.configuration).to be_a(TestReportKit::Configuration)
    end

    it "has sensible defaults" do
      config = TestReportKit.configuration
      expect(config.output_dir).to eq("tmp/test_report")
      expect(config.diff_base_branch).to eq("main")
      expect(config.coverage_threshold).to eq(80)
      expect(config.diff_coverage_threshold).to eq(90)
      expect(config.slow_test_threshold).to eq(5.0)
      expect(config.churn_days).to eq(90)
    end
  end

  describe ".configure" do
    it "yields the configuration" do
      TestReportKit.configure do |config|
        config.project_name = "my_project"
        config.output_dir = "custom/output"
        config.diff_base_branch = "develop"
      end

      expect(TestReportKit.configuration.project_name).to eq("my_project")
      expect(TestReportKit.configuration.output_dir).to eq("custom/output")
      expect(TestReportKit.configuration.diff_base_branch).to eq("develop")
    end
  end

  describe ".reset_configuration!" do
    it "resets to defaults" do
      TestReportKit.configure { |c| c.project_name = "changed" }
      TestReportKit.reset_configuration!
      expect(TestReportKit.configuration.project_name).to be_nil
    end
  end
end
