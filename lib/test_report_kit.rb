# frozen_string_literal: true

require_relative "test_report_kit/version"
require_relative "test_report_kit/configuration"

module TestReportKit
  class Error < StandardError; end

  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
    end

    def run!(mode: :full)
      require_relative "test_report_kit/runner"
      Runner.new(configuration, mode: mode).run!
    end
  end
end

require_relative "test_report_kit/railtie" if defined?(Rails::Railtie)
