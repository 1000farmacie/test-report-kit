# frozen_string_literal: true

require "json"
require "fileutils"

module TestReportKit
  class ParallelMerger
    def initialize(artifact_dirs:, config: TestReportKit.configuration)
      @dirs = artifact_dirs
      @config = config
    end

    def merge!
      FileUtils.mkdir_p(@config.output_dir)
      FileUtils.mkdir_p(simplecov_dir)

      merge_simplecov
      merge_rspec_results
      merge_factory_prof
      merge_event_prof
      merge_rspec_dissect
      merge_resource_usage
      copy_first("git_churn.json")
      save_parallel_info

      puts "TestReportKit: Merged #{@dirs.size} parallel nodes → #{@config.output_dir}"
    end

    private

    def collect(filename, subdirs: nil)
      search_dirs = subdirs || ["", "tmp/test_report"]
      @dirs.filter_map do |dir|
        found = search_dirs.map { |sub| File.join(dir, sub, filename) }.find { |p| File.exist?(p) }
        found
      end
    end

    def node_name(dir)
      File.basename(dir).sub(/^test-results-/, "node-")
    end

    # ── SimpleCov ──

    def merge_simplecov
      files = collect(".resultset.json", subdirs: ["coverage"])
      return if files.empty?

      merged = {}
      files.each_with_index do |f, i|
        data = JSON.parse(File.read(f))
        data.each do |command, result|
          key = "#{command}-node#{i}"
          merged[key] = result
        end
      end

      File.write(File.join(simplecov_dir, ".resultset.json"), JSON.pretty_generate(merged))
    end

    def simplecov_dir
      File.join(@config.project_root, "coverage")
    end

    # ── RSpec Results ──

    def merge_rspec_results
      files = collect("rspec_results.json")
      return if files.empty?

      all_examples = []
      total_duration = total_examples = total_failures = total_pending = 0

      files.each_with_index do |f, i|
        data = JSON.parse(File.read(f))
        node = node_name(File.dirname(f).sub(/\/tmp\/test_report$/, ""))

        (data["examples"] || []).each do |e|
          e["_node"] = node
          all_examples << e
        end

        s = data["summary"] || {}
        total_duration += s["duration"].to_f
        total_examples += s["example_count"].to_i
        total_failures += s["failure_count"].to_i
        total_pending  += s["pending_count"].to_i
      end

      merged = {
        "version" => "merged",
        "examples" => all_examples,
        "summary" => {
          "duration" => total_duration.round(3),
          "example_count" => total_examples,
          "failure_count" => total_failures,
          "pending_count" => total_pending
        }
      }
      write_merged("rspec_results.json", merged)
    end

    # ── FactoryProf ──

    def merge_factory_prof
      files = collect("factory_prof.json") + collect("test-prof.result.json", subdirs: ["tmp/test_prof"])
      return if files.empty?

      total_count = total_top_level = 0
      total_time = 0.0
      stats_by_name = Hash.new { |h, k| h[k] = { total_count: 0, top_level_count: 0, total_time: 0.0, top_level_time: 0.0 } }

      files.each do |f|
        data = JSON.parse(File.read(f))
        total_count += data["total_count"].to_i
        total_top_level += data["total_top_level_count"].to_i

        (data["stats"] || []).each do |s|
          entry = stats_by_name[s["name"]]
          entry[:total_count] += s["total_count"].to_i
          entry[:top_level_count] += s["top_level_count"].to_i
          entry[:total_time] += s["total_time"].to_f
          entry[:top_level_time] += (s["top_level_time"] || 0).to_f
        end
      end

      merged = {
        "total_count" => total_count,
        "total_top_level_count" => total_top_level,
        "total_time" => "#{total_time.round(2)}s",
        "total_uniq_factories" => stats_by_name.size,
        "stats" => stats_by_name.map { |name, s| { "name" => name }.merge(s.transform_keys(&:to_s)) }
      }
      write_merged("factory_prof.json", merged)
    end

    # ── EventProf ──

    def merge_event_prof
      files = collect("event_prof.json")
      return if files.empty?

      total_events = 0
      event_name = nil
      suites_by_loc = {}

      files.each do |f|
        data = JSON.parse(File.read(f))
        event_name ||= data["event"]
        total_events += data["total_events"].to_i

        (data["suites"] || []).each do |s|
          loc = s["location"]
          if suites_by_loc[loc]
            suites_by_loc[loc]["event_count"] = suites_by_loc[loc]["event_count"].to_i + s["event_count"].to_i
            suites_by_loc[loc]["example_count"] = suites_by_loc[loc]["example_count"].to_i + s["example_count"].to_i
          else
            suites_by_loc[loc] = s.dup
          end
        end
      end

      merged = {
        "event" => event_name,
        "total_events" => total_events,
        "suites" => suites_by_loc.values
      }
      write_merged("event_prof.json", merged)
    end

    # ── RSpecDissect ──

    def merge_rspec_dissect
      files = collect("rspec_dissect.json")
      return if files.empty?

      suites_by_loc = {}
      files.each do |f|
        data = JSON.parse(File.read(f))
        (data["suites"] || []).each do |s|
          loc = s["location"]
          suites_by_loc[loc] ||= s.dup
        end
      end

      merged = { "suites" => suites_by_loc.values }
      write_merged("rspec_dissect.json", merged)
    end

    # ── Resource Usage ──

    def merge_resource_usage
      files = collect("resource_usage.json")
      return if files.empty?

      max_mem = 0
      total_cpu_user = total_cpu_sys = 0.0

      files.each do |f|
        data = JSON.parse(File.read(f))
        max_mem = [max_mem, data["peak_memory_mb"].to_i].max
        total_cpu_user += data["cpu_user_seconds"].to_f
        total_cpu_sys += data["cpu_system_seconds"].to_f
      end

      merged = {
        "peak_memory_mb" => max_mem,
        "cpu_user_seconds" => total_cpu_user.round(1),
        "cpu_system_seconds" => total_cpu_sys.round(1)
      }
      write_merged("resource_usage.json", merged)
    end

    # ── Parallel Info ──

    def save_parallel_info
      rspec_path = File.join(@config.output_dir, "rspec_results.json")
      return unless File.exist?(rspec_path)

      data = JSON.parse(File.read(rspec_path))
      examples = data["examples"] || []
      nodes = examples.group_by { |e| e["_node"] || "unknown" }

      node_stats = nodes.map do |node, exs|
        duration = exs.sum { |e| e["run_time"].to_f }
        failures = exs.count { |e| e["status"] == "failed" }
        slowest = exs.max_by { |e| e["run_time"].to_f }
        {
          "node" => node,
          "examples" => exs.size,
          "duration" => duration.round(3),
          "failures" => failures,
          "slowest_test" => slowest&.dig("full_description")&.to_s&.[](0..60),
          "slowest_duration" => slowest&.dig("run_time")&.round(3)
        }
      end.sort_by { |n| n["node"] }

      durations = node_stats.map { |n| n["duration"] }
      avg = durations.sum / durations.size if durations.any?
      max_dur = durations.max || 0
      wall_clock = max_dur # parallel wall clock = slowest node

      info = {
        "node_count" => node_stats.size,
        "wall_clock_seconds" => wall_clock.round(3),
        "total_cpu_seconds" => durations.sum.round(3),
        "efficiency" => wall_clock > 0 ? ((durations.sum / (wall_clock * node_stats.size)) * 100).round(1) : 0,
        "nodes" => node_stats,
        "balance" => balance_analysis(node_stats, avg)
      }
      write_merged("parallel_info.json", info)
    end

    def balance_analysis(node_stats, avg)
      return [] unless avg && avg > 0

      node_stats.filter_map do |n|
        pct_diff = ((n["duration"] - avg) / avg * 100).round(0)
        next if pct_diff.abs < 20

        {
          "node" => n["node"],
          "message" => pct_diff > 0 ?
            "#{n['node']} took #{pct_diff}% longer than average — consider rebalancing" :
            "#{n['node']} finished #{pct_diff.abs}% faster than average — could take more tests"
        }
      end
    end

    # ── Helpers ──

    def copy_first(filename)
      files = collect(filename)
      return if files.empty?
      FileUtils.cp(files.first, File.join(@config.output_dir, filename))
    end

    def write_merged(filename, data)
      File.write(File.join(@config.output_dir, filename), JSON.pretty_generate(data))
    end
  end
end
