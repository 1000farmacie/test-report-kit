# frozen_string_literal: true

module TestReportKit
  class Railtie < Rails::Railtie
    rake_tasks do
      load File.expand_path("../tasks/test_report_kit.rake", __dir__)
    end
  end
end
