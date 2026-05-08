# frozen_string_literal: true

require "json"

module TestReportKit
  class DataLoader
    attr_reader :simplecov_data, :rspec_data, :factory_prof_data,
                :event_prof_data, :rspec_dissect_data, :git_churn_data,
                :resource_usage_data, :parallel_info_data

    def initialize(config: TestReportKit.configuration)
      @config = config
    end

    def load_all
      @simplecov_data    = load_simplecov
      @rspec_data        = load_json(rspec_results_path)
      @factory_prof_data = load_json(factory_prof_path)
      @event_prof_data   = load_json(event_prof_path)
      @rspec_dissect_data = load_json(rspec_dissect_path)
      @git_churn_data    = load_json(git_churn_path)
      @resource_usage_data = load_json(resource_usage_path)
      @parallel_info_data  = load_json(parallel_info_path)
      self
    end

    private

    def load_simplecov
      path = simplecov_path
      return nil unless File.exist?(path)

      raw = JSON.parse(File.read(path))
      merge_coverage_results(raw)
    rescue JSON::ParserError => e
      warn "TestReportKit: Failed to parse SimpleCov data: #{e.message}"
      nil
    end

    def merge_coverage_results(raw)
      merged = {}

      raw.each do |_command_name, command_data|
        next unless command_data.is_a?(Hash) && command_data["coverage"]

        command_data["coverage"].each do |filename, data|
          normalized = normalize_file_coverage(data)
          if merged[filename]
            merged[filename] = merge_file_coverage(merged[filename], normalized)
          else
            merged[filename] = normalized
          end
        end
      end

      merged
    end

    def normalize_file_coverage(data)
      if data.is_a?(Array)
        { "lines" => data, "branches" => {} }
      else
        { "lines" => data["lines"] || [], "branches" => data.fetch("branches", {}) }
      end
    end

    def merge_file_coverage(a, b)
      merged_lines = a["lines"].zip(b["lines"]).map do |x, y|
        next nil if x.nil? && y.nil?
        (x || 0) + (y || 0)
      end
      { "lines" => merged_lines, "branches" => a["branches"].merge(b.fetch("branches", {})) }
    end

    def load_json(path)
      return nil unless path && File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      warn "TestReportKit: Failed to parse #{path}: #{e.message}"
      nil
    end

    # File path helpers

    def simplecov_path
      File.join(@config.project_root, "coverage", ".resultset.json")
    end

    def rspec_results_path
      File.join(@config.output_dir, "rspec_results.json")
    end

    def factory_prof_path
      candidates = [
        File.join(@config.output_dir, "factory_prof.json"),
        File.join(@config.project_root, "tmp", "test_prof", "factory_prof.json"),
        File.join(@config.project_root, "tmp", "test_prof", "test-prof.result.json")
      ]
      found = candidates.find { |p| File.exist?(p) }
      return found if found

      # Glob for timestamped variants
      Dir.glob(File.join(@config.project_root, "tmp", "test_prof", "test-prof.result*.json"))
         .max_by { |f| File.mtime(f) }
    end

    def event_prof_path    = find_prof_file("event_prof")
    def rspec_dissect_path = find_prof_file("rspec_dissect")

    def find_prof_file(name)
      [
        File.join(@config.output_dir, "#{name}.json"),
        File.join(@config.project_root, "tmp", "test_prof", "#{name}.json")
      ].find { |p| File.exist?(p) }
    end

    def git_churn_path
      File.join(@config.output_dir, "git_churn.json")
    end

    def resource_usage_path
      File.join(@config.output_dir, "resource_usage.json")
    end

    def parallel_info_path
      File.join(@config.output_dir, "parallel_info.json")
    end
  end
end
