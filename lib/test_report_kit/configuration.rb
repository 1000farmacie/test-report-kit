# frozen_string_literal: true

module TestReportKit
  class Configuration
    attr_accessor :project_name,
                  :output_dir,
                  :profilers,
                  :churn_days,
                  :coverage_threshold,
                  :diff_coverage_threshold,
                  :diff_base_branch,
                  :slow_test_threshold,
                  :factory_cascade_threshold,
                  :project_root,
                  :github_url,
                  :event_prof_event,
                  :fail_on_coverage,
                  :fail_on_diff_coverage,
                  :simplecov_track_files

    def initialize
      @project_name             = nil
      @output_dir               = "tmp/test_report"
      @profilers                = %i[factory_prof rspec_dissect event_prof]
      @churn_days               = 90
      @coverage_threshold       = 80
      @diff_coverage_threshold  = 90
      @diff_base_branch         = "main"
      @slow_test_threshold      = 5.0
      @factory_cascade_threshold = 10
      @project_root             = Dir.pwd
      @github_url               = nil
      @event_prof_event         = "factory.create"
      @fail_on_coverage         = false
      @fail_on_diff_coverage    = false
      # Glob describing application code that SimpleCov is responsible for.
      # Used by churn-based insights to skip non-Ruby files (locales, schema,
      # migrations, JSON fixtures) that show up in git churn but aren't testable.
      @simplecov_track_files    = "{app,lib}/**/*.rb"
    end

    def resolved_project_name
      @project_name || File.basename(project_root)
    end
  end
end
