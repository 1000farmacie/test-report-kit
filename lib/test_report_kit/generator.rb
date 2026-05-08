# frozen_string_literal: true

require "erb"
require "json"
require "set"
require "fileutils"
require "strscan"

module TestReportKit
  class Generator
    TEMPLATE_DIR = File.expand_path("templates", __dir__)

    def initialize(metrics:, diff_coverage:, data_loader:, config: TestReportKit.configuration, markdown_content: nil)
      @metrics          = metrics
      @diff_coverage    = diff_coverage
      @data_loader      = data_loader
      @config           = config
      @markdown_content = markdown_content
    end

    def generate
      html = render_template("dashboard")
      output_path = File.join(@config.output_dir, "index.html")
      FileUtils.mkdir_p(@config.output_dir)
      File.write(output_path, html)
      output_path
    end

    private

    def render_template(name)
      path = File.join(TEMPLATE_DIR, "#{name}.html.erb")
      template = File.read(path)
      ERB.new(template, trim_mode: "-").result(binding)
    end

    def render_partial(name)
      path = File.join(TEMPLATE_DIR, "_#{name}.html.erb")
      template = File.read(path)
      ERB.new(template, trim_mode: "-").result(binding)
    end

    # ── Data accessors for templates ──

    def project_name
      @config.resolved_project_name
    end

    def timestamp
      Time.now.strftime("%b %d, %Y · %H:%M %Z").downcase
    end

    def branch
      ENV.fetch("TEST_REPORT_BRANCH", `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip)
    end

    def sha
      ENV.fetch("TEST_REPORT_SHA", `git rev-parse --short HEAD 2>/dev/null`.strip)[0..6]
    end

    def overall_coverage
      @metrics[:overall_coverage]
    end

    def file_coverage
      @metrics[:file_coverage] || []
    end

    def rspec_summary
      @metrics[:rspec_summary]
    end

    def slowest_tests
      @metrics[:slowest_tests] || []
    end

    def failed_tests
      @metrics[:failed_tests] || []
    end

    def test_time_distribution
      @metrics[:test_time_distribution]
    end

    def time_by_file
      @metrics[:time_by_file] || []
    end

    def build_test_source(file_path, line_number, max_lines: 30)
      path = file_path.to_s.sub(%r{^\./}, "")
      abs_path = File.join(@config.project_root, path)
      return nil unless File.exist?(abs_path)

      all_lines = File.readlines(abs_path, chomp: true)
      start = [line_number.to_i - 1, 0].max
      first_line = all_lines[start]
      return nil unless first_line

      indent = first_line[/\A\s*/].length
      result = []

      all_lines[start..].each_with_index do |line, i|
        if i > 0 && line.strip == "end" && line[/\A\s*/].length <= indent
          result << { line: start + i + 1, content: line }
          break
        end
        result << { line: start + i + 1, content: line }
        break if result.size >= max_lines
      end

      result
    end

    def factory_health
      @metrics[:factory_health]
    end

    def insights
      @metrics[:insights] || {}
    end

    def diff_cov
      @diff_coverage
    end

    # ── PR scope helpers (used by dashboard's PR-only filter) ──
    #
    # When diff coverage is available, has_pr? is true and the dashboard
    # adds a top-level toggle (default: PR only) that filters every
    # file-listing table to rows whose path matches a PR-changed file
    # (or, for spec-file rows, whose source equivalent is in the PR).

    def pr_files_set
      @pr_files_set ||= @diff_coverage ? Set.new(@diff_coverage.files.map(&:path)) : nil
    end

    def pr_spec_files_set
      @pr_spec_files_set ||= begin
        paths = @metrics.dig(:pr_metrics, :pr_spec_paths)
        paths ? Set.new(paths) : nil
      end
    end

    def pr_metrics
      @metrics[:pr_metrics]
    end

    def has_pr?
      pr_files_set && !pr_files_set.empty?
    end

    def in_pr?(path)
      return false unless pr_files_set
      pr_files_set.include?(path.to_s)
    end

    def in_pr_spec?(spec_file)
      return false unless pr_spec_files_set
      normalized = spec_file.to_s.sub(%r{^\./}, "").split(":").first
      pr_spec_files_set.include?(normalized)
    end

    def rspec_dissect_data
      @data_loader.rspec_dissect_data
    end

    def event_prof_data
      @data_loader.event_prof_data
    end

    # ── Formatting helpers ──

    def coverage_color(pct)
      return "var(--text-muted)" unless pct
      if pct >= 80 then "var(--green)"
      elsif pct >= 60 then "var(--yellow)"
      else "var(--red)"
      end
    end

    def risk_color(score)
      if score >= 500 then "var(--red)"
      elsif score >= 200 then "var(--yellow)"
      else "var(--green)"
      end
    end

    def risk_bg(score)
      if score >= 500 then "var(--red-dim)"
      elsif score >= 200 then "var(--yellow-dim)"
      else "var(--green-dim)"
      end
    end

    def severity_color(severity)
      case severity
      when "critical" then "var(--red)"
      when "high" then "var(--orange)"
      when "medium" then "var(--yellow)"
      else "var(--text-muted)"
      end
    end

    GH_ICON_SVG = '<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor" style="vertical-align: -2px;"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>'

    def gh_link(path, line: nil)
      return "" unless @config.github_url
      url = "#{@config.github_url}/blob/#{sha}/#{path}"
      url += "#L#{line}" if line
      %( <a href="#{h(url)}" target="_blank" rel="noopener" title="Open on GitHub" class="gh-icon">#{GH_ICON_SVG}</a>)
    end

    def file_link(path, line: nil)
      "#{h(path)}#{gh_link(path, line: line)}"
    end

    def factory_file_link(name)
      n = name.to_s
      plural = if n.end_with?("y") && !n.end_with?("ey", "ay", "oy", "uy")
                 n.sub(/y$/, "ies")
               elsif n.end_with?("s", "x", "ch", "sh")
                 "#{n}es"
               else
                 "#{n}s"
               end
      gh_link("spec/factories/#{plural}.rb")
    end

    def resource_usage
      @data_loader.respond_to?(:resource_usage_data) ? @data_loader.resource_usage_data : nil
    end

    def parallel_info
      @data_loader.respond_to?(:parallel_info_data) ? @data_loader.parallel_info_data : nil
    end

    def markdown_content
      @markdown_content
    end

    def embedded_markdown
      return "" unless @markdown_content
      @markdown_content.gsub("</script>", "<\\/script>")
    end

    def format_duration_val(seconds)
      return "—" unless seconds
      s = seconds.to_f
      if s >= 60
        "#{(s / 60).floor}m #{(s % 60).round(0)}s"
      elsif s >= 1
        "#{s.round(1)}s"
      else
        "#{(s * 1000).round(0)}ms"
      end
    end

    def format_number(n)
      return "—" unless n
      n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end

    def h(text)
      ERB::Util.html_escape(text.to_s)
    end

    def highlight_ruby(code)
      return "" if code.nil? || code.empty?

      result = +""
      scanner = StringScanner.new(code)
      until scanner.eos?
        if scanner.scan(/#.*$/)
          result << %(<span style="color: var(--text-muted);">#{h(scanner.matched)}</span>)
        elsif scanner.scan(/"[^"]*"|'[^']*'/)
          result << %(<span style="color: #98c379;">#{h(scanner.matched)}</span>)
        elsif scanner.scan(/:[a-zA-Z_]\w*/)
          result << %(<span style="color: #98c379;">#{h(scanner.matched)}</span>)
        elsif scanner.scan(/\b(?:def|end|if|else|elsif|unless|do|class|module|raise|return|next|begin|rescue|ensure|yield|nil|true|false|self)\b/)
          result << %(<span style="color: #c678dd;">#{h(scanner.matched)}</span>)
        elsif scanner.scan(/\b[A-Z][a-zA-Z0-9]*(?:::[A-Z][a-zA-Z0-9]*)*\b/)
          result << %(<span style="color: var(--cyan);">#{h(scanner.matched)}</span>)
        else
          result << h(scanner.scan(/./m))
        end
      end
      result
    end

    def build_file_line_data(relative_path)
      lines_array = resolve_simplecov_lines(relative_path)
      return nil unless lines_array

      source_path = File.join(@config.project_root, relative_path)
      return nil unless File.exist?(source_path)

      source_lines = File.readlines(source_path, chomp: true)
      source_lines.each_with_index.map do |content, idx|
        { line: idx + 1, executed: lines_array[idx], content: content }
      end
    end

    def json_data
      {
        diff_coverage: @diff_coverage&.to_h,
        file_coverage: file_coverage,
        factory_health: factory_health,
        insights: insights
      }.to_json
    end

    def coverage_file_data_json
      return "{}" unless @data_loader.simplecov_data

      result = {}
      file_coverage.each do |f|
        next if f[:coverage_pct] >= 100

        line_data = resolve_simplecov_lines(f[:path])
        next unless line_data

        source_path = File.join(@config.project_root, f[:path])
        next unless File.exist?(source_path)

        result[f[:path]] = {
          lines: File.readlines(source_path, chomp: true),
          cov: line_data
        }
      end

      result.to_json
    end

    def coverage_config_json
      { github_url: @config.github_url, sha: sha }.to_json
    end

    def all_passing?
      return true unless rspec_summary
      (rspec_summary[:failure_count] || 0) == 0
    end

    private

    def resolve_simplecov_lines(relative_path)
      simplecov = @data_loader.simplecov_data
      return nil unless simplecov

      abs_path = File.join(@config.project_root, relative_path)
      cov_data = simplecov[abs_path]

      unless cov_data
        simplecov.each do |path, data|
          if path.end_with?("/#{relative_path}")
            cov_data = data
            break
          end
        end
      end
      return nil unless cov_data

      cov_data.is_a?(Hash) ? cov_data["lines"] : cov_data
    end
  end
end
