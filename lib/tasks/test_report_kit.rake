# frozen_string_literal: true

require "test_report_kit"

namespace :test_report do
  desc "Run full test suite with coverage, profiling, and diff coverage — generate HTML dashboard"
  task full: :environment do
    exit TestReportKit.run!(mode: :full)
  end

  desc "Run tests with coverage only (no profiling) — faster"
  task coverage: :environment do
    exit TestReportKit.run!(mode: :coverage)
  end

  desc "Run tests with profiling only (no coverage)"
  task profile: :environment do
    exit TestReportKit.run!(mode: :profile)
  end

  desc "Re-generate HTML dashboard from existing JSON files (no test run)"
  task generate: :environment do
    exit TestReportKit.run!(mode: :generate)
  end

  desc "Merge parallel test artifacts and generate report. Usage: rake test_report:merge[pattern]"
  task :merge, [:pattern] => :environment do |_t, args|
    require "test_report_kit/parallel_merger"

    pattern = args[:pattern] || "test-results-*"
    dirs = Dir.glob(pattern).select { |f| File.directory?(f) }

    if dirs.empty?
      puts "TestReportKit: No artifact directories found matching '#{pattern}'"
      exit 1
    end

    puts "TestReportKit: Merging #{dirs.size} parallel nodes: #{dirs.join(', ')}"
    TestReportKit::ParallelMerger.new(
      artifact_dirs: dirs,
      config: TestReportKit.configuration
    ).merge!

    exit TestReportKit.run!(mode: :generate)
  end
end
