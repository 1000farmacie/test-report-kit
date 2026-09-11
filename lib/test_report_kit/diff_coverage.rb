# frozen_string_literal: true

require "open3"
require "set"

module TestReportKit
  # Computes coverage for lines changed in the current branch against a base ref
  # (`diff_base_branch`, default "main"). The base ref is used ONLY to derive the
  # git diff (which lines changed) — coverage data from main is NEVER fetched or
  # compared. Every run is independent: the percentage reflects only the current
  # RSpec run's SimpleCov data, restricted to lines that appear in the diff.
  #
  # This intentionally provides a "you must test what you change" gate rather
  # than a "your coverage didn't drop vs main" gate. For the latter, persist
  # summary.json from main runs and compare client-side.
  class DiffCoverage
    HUNK_HEADER_RE = /^@@\s+-\d+(?:,\d+)?\s+\+(\d+)(?:,(\d+))?\s+@@/
    DIFF_FILE_RE   = /^diff --git a\/.+ b\/(.+)$/
    RUBY_APP_RE    = /\A(?:app|lib)\/.+\.rb\z/

    # `diff_base_branch` reaches git as an argument, so it is validated before use.
    # Git refname rules permit `;`, `|`, `&` and `$()` — and `${IFS}` sidesteps the
    # ban on spaces — so a base branch taken from ENV, YAML or a CI variable rather
    # than a literal is untrusted input.
    #
    # Argv form is the actual defence: nothing here reaches a shell. This allowlist
    # is the second layer, and also keeps git from reading a ref as an option, hence
    # the restricted first character (`--upload-pack=...` is rejected).
    #
    # Unicode letters are deliberately allowed — `développement` and `主分支` are
    # valid branch names, and rejecting them would silently disable the gate.
    BASE_REF_RE = %r{\A[\p{L}\p{N}_][\p{L}\p{N}._/+-]*\z}

    Result = Struct.new(
      :base_branch, :base_sha, :head_sha,
      :total_changed_lines, :executable_changed_lines,
      :covered_changed_lines, :uncovered_changed_lines,
      :diff_coverage_pct, :threshold, :passed, :files,
      keyword_init: true
    )

    FileCoverage = Struct.new(
      :path, :changed_lines, :covered_lines, :uncovered_lines,
      :non_executable_lines, :diff_coverage_pct, :not_loaded,
      :uncovered_content,
      keyword_init: true
    )

    def initialize(coverage_data:, config: TestReportKit.configuration)
      @coverage_data = coverage_data
      @config = config
      @coverage_index = build_coverage_index
    end

    def call
      diff_text = run_git_diff
      return nil if diff_text.nil? || diff_text.strip.empty?

      changed_files = parse_git_diff(diff_text)
      return nil if changed_files.empty?

      file_results = changed_files.map { |path, lines| analyze_file(path, lines) }

      total_changed     = file_results.sum { |f| f.changed_lines.size }
      total_executable  = file_results.sum { |f| f.covered_lines.size + f.uncovered_lines.size }
      total_covered     = file_results.sum { |f| f.covered_lines.size }
      total_uncovered   = file_results.sum { |f| f.uncovered_lines.size }
      pct = total_executable > 0 ? (total_covered.to_f / total_executable * 100).round(1) : nil

      Result.new(
        base_branch: @config.diff_base_branch,
        base_sha: git_merge_base,
        head_sha: git_head_sha,
        total_changed_lines: total_changed,
        executable_changed_lines: total_executable,
        covered_changed_lines: total_covered,
        uncovered_changed_lines: total_uncovered,
        diff_coverage_pct: pct,
        threshold: @config.diff_coverage_threshold,
        passed: pct.nil? ? nil : pct >= @config.diff_coverage_threshold,
        files: file_results.sort_by { |f| f.diff_coverage_pct || -1 }
      )
    end

    def parse_git_diff(diff_text)
      files = {}
      current_file = nil

      diff_text.each_line do |line|
        if (match = line.match(DIFF_FILE_RE))
          candidate = match[1]
          current_file = RUBY_APP_RE.match?(candidate) ? candidate : nil
        elsif current_file && (match = line.match(HUNK_HEADER_RE))
          start_line = match[1].to_i
          count = (match[2] || "1").to_i
          next if count == 0 # pure deletion

          files[current_file] ||= []
          (start_line...(start_line + count)).each { |n| files[current_file] << n }
        end
      end

      files.each_value(&:uniq!)
      files
    end

    private

    def analyze_file(relative_path, changed_lines)
      absolute_path = File.join(@config.project_root, relative_path)
      file_coverage = find_coverage(absolute_path)

      covered = []
      uncovered = []
      non_executable = []
      not_loaded = file_coverage.nil?

      changed_lines.each do |line_num|
        if not_loaded
          uncovered << line_num
        else
          line_cov = file_coverage[line_num - 1] # 0-indexed array
          if line_cov.nil?
            non_executable << line_num
          elsif line_cov > 0
            covered << line_num
          else
            uncovered << line_num
          end
        end
      end

      executable = covered.size + uncovered.size
      pct = executable > 0 ? (covered.size.to_f / executable * 100).round(1) : nil

      FileCoverage.new(
        path: relative_path,
        changed_lines: changed_lines,
        covered_lines: covered,
        uncovered_lines: uncovered,
        non_executable_lines: non_executable,
        diff_coverage_pct: pct,
        not_loaded: not_loaded,
        uncovered_content: not_loaded ? [] : build_uncovered_content(relative_path, uncovered)
      )
    end

    def build_uncovered_content(relative_path, uncovered)
      return [] if uncovered.empty?

      source_path = File.join(@config.project_root, relative_path)
      return [] unless File.exist?(source_path)

      source_lines = File.readlines(source_path, chomp: true)
      content = []
      emitted = Set.new

      group_consecutive_lines(uncovered).each_with_index do |group, idx|
        content << { type: :gap } if idx > 0

        # 1 context line before (skip if already emitted)
        ctx_before = group.first - 1
        if ctx_before >= 1 && ctx_before <= source_lines.size && !uncovered.include?(ctx_before) && emitted.add?(ctx_before)
          content << { type: :context, line: ctx_before, content: source_lines[ctx_before - 1] }
        end

        # Uncovered lines
        group.each do |line_num|
          next if line_num < 1 || line_num > source_lines.size
          emitted.add(line_num)
          content << { type: :uncovered, line: line_num, content: source_lines[line_num - 1] }
        end

        # 1 context line after (skip if already emitted)
        ctx_after = group.last + 1
        if ctx_after >= 1 && ctx_after <= source_lines.size && !uncovered.include?(ctx_after) && emitted.add?(ctx_after)
          content << { type: :context, line: ctx_after, content: source_lines[ctx_after - 1] }
        end
      end

      content
    end

    def group_consecutive_lines(lines)
      return [] if lines.empty?
      lines.sort.chunk_while { |a, b| b == a + 1 }.to_a
    end

    def find_coverage(absolute_path)
      relative = absolute_path.sub(%r{^#{Regexp.escape(@config.project_root)}/?}, "")
      @coverage_index[absolute_path] || @coverage_index[relative]
    end

    def build_coverage_index
      index = {}
      return index unless @coverage_data

      @coverage_data.each do |path, data|
        lines = data.is_a?(Hash) ? data["lines"] : data
        index[path] = lines
        # Also index by relative path suffix
        relative = path.sub(%r{^#{Regexp.escape(@config.project_root)}/?}, "")
        index[relative] = lines
      end
      index
    end

    def run_git_diff
      base = resolve_base_ref
      return nil unless base

      git_capture("diff", "#{base}...HEAD", "--unified=0", "--no-color",
                  "--diff-filter=ACMR", "--find-renames")
    end

    # Memoised so a run resolves the base ref once instead of per call site, and so
    # a rejected ref warns once rather than on every caller.
    def resolve_base_ref
      return @resolved_base_ref if defined?(@resolved_base_ref)

      @resolved_base_ref = compute_base_ref
    end

    def compute_base_ref
      base = @config.diff_base_branch.to_s
      unless base.match?(BASE_REF_RE)
        # Never fail silently here. A rejected ref disables diff coverage, and the
        # dashboard renders that identically to "this branch has no diff" — so
        # without this line a typo'd or exotic branch name looks like a passing gate.
        warn "TestReportKit: diff_base_branch #{base.inspect} is not a usable branch name — skipping diff coverage"
        return nil
      end

      [base, "origin/#{base}"].each do |ref|
        result = git_capture("rev-parse", "--verify", ref).to_s.strip
        return result[0..11] unless result.empty?
      end
      nil
    end

    def git_merge_base
      base = resolve_base_ref
      return "" unless base

      git_capture("merge-base", base, "HEAD").to_s.strip[0..6].to_s
    end

    def git_head_sha
      git_capture("rev-parse", "--short", "HEAD").to_s.strip
    end

    # Runs git in argv form so arguments are passed to execve directly and are
    # never parsed by a shell. Returns nil on non-zero exit or a missing binary,
    # matching the previous backtick behaviour (callers treat nil as "no git").
    def git_capture(*args)
      stdout, _stderr, status = Open3.capture3("git", *args)
      status.success? ? stdout : nil
    rescue Errno::ENOENT
      nil
    end
  end
end
