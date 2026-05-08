# frozen_string_literal: true

require_relative "lib/test_report_kit/version"

Gem::Specification.new do |spec|
  spec.name          = "test_report_kit"
  spec.version       = TestReportKit::VERSION
  spec.authors       = ["1000farmacie"]
  spec.summary       = "Unified RSpec coverage + profiling HTML dashboard"
  spec.description   = "Replaces Codecov with a free, self-hosted test reporting tool. " \
                        "Combines SimpleCov coverage, test-prof profiling, diff coverage, " \
                        "and git churn analysis into a single static HTML dashboard."
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.homepage = "https://github.com/1000farmacie/test-report-kit"
  spec.metadata = {
    "homepage_uri"    => spec.homepage,
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri"   => "#{spec.homepage}/blob/main/CHANGELOG.md"
  }

  spec.files         = Dir["lib/**/*", "exe/*", "LICENSE.txt"]
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
