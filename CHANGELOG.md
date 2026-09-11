# Changelog

All notable changes to `test_report_kit` are documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

## [0.4.4] - 2026-09-11

### Security
- **Escaped `sha` and the spec path in the report's GitHub links.** The four
  hand-written links in `_tab_failures.html.erb` and `_tab_performance.html.erb`
  interpolated `sha` and `test_file` into an `href` without escaping, unlike
  `gh_link`, which escapes the whole URL. `test_file` comes straight from the
  RSpec JSON, so a spec filename containing a double quote — something any
  contributor can create in a pull request — closed the attribute and injected
  an event handler into the generated dashboard, which CI then publishes.
  `sha` was injectable the same way via `TEST_REPORT_SHA`, though truncation to
  seven characters limited it to a malformed tag.

  All four links now escape every interpolated component.

- **Escaped the same values in the client-side coverage viewer.**
  `buildViewer` in `dashboard.html.erb` rebuilds that link in JavaScript and
  assigns it through `innerHTML`, escaping only `github_url` — not the file path
  or `sha`. Opening a poisoned file in the viewer put a live event handler in the
  DOM. The comment claiming all text content was escaped was wrong, and has been
  corrected along with the code.

- **Stopped the embedded JSON blocks from closing their own `<script>` element.**
  `to_json` escapes neither `<` nor `/`, so any string reaching `report-data`,
  `cov-file-data` or `cov-config` could emit a literal `</script>` and turn the
  remainder of the document into live markup — with no quote character involved.
  `cov-file-data` embeds the full source of every uncovered `app/` and `lib/`
  file, so this was reachable from ordinary repository content. All three blocks
  now escape `<` and `>` as `\u003c`/`\u003e`, which stays valid JSON and parses
  back byte-identical.

- **Completed the same defence in the embedded markdown block.**
  `embedded_markdown` neutralised only the exact lowercase `</script>`, but an
  HTML parser also ends the element on `</SCRIPT>`, `</script >`, `</script/>`
  and `</script` followed by a tab or newline — each confirmed to terminate it.
  `report.md` embeds uncovered source lines verbatim, so this was reachable from
  ordinary repository content, and a markdown body containing
  `</SCRIPT><img src=x onerror=…>` produced a live element in the report. Now
  matched case-insensitively without requiring the closing `>`, preserving the
  original case so copied markdown still reads as written.

- **Escaped the remaining strings read from profiler JSON** — the RSpec status
  fallback, and the `total_time` / `total_run_time` / `total_events` /
  `total_percentage` fields from FactoryProf, EventProf and RSpecDissect. These
  were not reachable the way a spec filename is, so this is defence in depth
  rather than a fix; the invariant is now simply that no raw string from a JSON
  artifact reaches the document.

- **Escaped the factory optimisation suggestions**
  (`_tab_factories.html.erb:104`), which rendered a message containing a factory
  name as raw HTML.

  Three specs lock these: a ratchet over every interpolation inside any HTML
  attribute, a check that each JSON helper cannot emit `</script>`, and a guard
  on the client-side link builder. Each was confirmed to fail when its fix is
  reverted.

## [0.4.3] - 2026-09-11

### Security
- **Fixed shell injection in the git invocations** (`diff_coverage.rb`,
  `runner.rb`). `config.diff_base_branch` and `config.churn_days` were
  interpolated into backtick strings, so both reached `/bin/sh` verbatim. Git
  refname rules permit `;`, `|`, `&` and `$()` — and `${IFS}` sidesteps the ban
  on spaces — so any deployment that sourced either value from ENV, YAML or a CI
  variable rather than a literal could execute arbitrary commands on the runner.
  `churn_days` needed a quote-breaking payload (`90' ; … ; echo '`) because that
  command single-quoted it; `diff_base_branch` was unquoted and took any payload.

  Both git calls that interpolate a value now use argv form via `Open3.capture3`,
  which passes arguments straight to `execve` and never invokes a shell. (The
  remaining backticks in `generator.rb`, `summary_exporter.rb` and
  `markdown_exporter.rb` run fixed command strings with nothing interpolated.)
  As a second layer, `diff_base_branch` is validated against
  `/\A[\p{L}\p{N}_][\p{L}\p{N}._\/+-]*\z/` — the leading character is
  restricted so a ref can never be read by git as an option such as
  `--upload-pack`, while Unicode letters stay valid — and `churn_days` is coerced
  with `Integer()`. A rejected base branch now warns instead of silently
  disabling the diff-coverage gate.

  Projects that set neither option, or set them to literal values, were not
  affected.

### Changed
- A malformed `churn_days` now warns and skips the churn panel instead of
  aborting the run, and a missing `git` binary is handled the same way.

## [0.4.2] - 2026-05-21

### Added
- **Clickable code links in the markdown PR comment.** When `github_url` is
  configured (already required for the HTML dashboard), the comment now links:
  - each **"Files changed"** row to its diff on the PR "Files changed" tab
    (`/pull/<n>/files#diff-<sha256(path)>`) — requires the new
    `config.github_pr_number` (or `TEST_REPORT_PR_NUMBER` env); falls back to
    the blob view of the file at the tested SHA when no PR number is available;
  - each **"Slowest related tests"** row and each **"Failing Tests"** header to
    its spec source at the exact line (`/blob/<sha>/<path>#L<line>`), the same
    URL shape the HTML report already uses.

  When `github_url` is unset the comment renders bare `` `path` `` text exactly
  as before. Table cells now escape `|`/`[`/`]` so a pipe or bracket in a test
  name can no longer break the table or a link.

### Configuration
- New `config.github_pr_number` (default `nil`); also read from the
  `TEST_REPORT_PR_NUMBER` environment variable.

## [0.4.1] - 2026-05-18

### Changed
- **RSpec stdout is now teed to the console** in addition to the captured
  `test_output.log`. Previously the runner redirected the child process's
  output straight to the log file, leaving CI step logs with only
  `TestReportKit: Running RSpec...` / `RSpec finished with exit code 1` and
  nothing in between. Now progress dots, the `Failures:` block, and the final
  summary stream to the terminal as RSpec emits them, so a failing CI step is
  diagnosable without downloading the HTML artifact or opening the PR comment.
  Implemented via `IO.popen` + `readpartial`; byte-for-byte content of
  `test_output.log` is preserved so the downstream profiler parsers keep
  working unchanged.

## [0.4.0] - 2026-05-12

### Added
- **`## Failing Tests` section in the markdown report** listing each failing
  test with its spec `file:line`, full description, and exception class +
  message (truncated to 500 bytes). Capped at 10 failures with a
  "…and N more" footer pointing readers to the HTML dashboard for the rest;
  tests whose spec file maps to a PR-changed source file are prefixed with
  🔴 — the same "related" logic already used by `pr_metrics`. Removes the
  need to download the HTML artifact to learn which test failed.

## [0.3.1] - 2026-05-08

### Changed
- Migrated to `1000farmacie/test-report-kit`. Update your `Gemfile`:
  ```ruby
  gem "test_report_kit", github: "1000farmacie/test-report-kit", tag: "v0.3.1"
  ```
- Gemspec: added `homepage` and `metadata` (`source_code_uri`, `bug_tracker_uri`, `changelog_uri`).
- README: documented the recommended sticky-PR-comment CI shape inline (replaces the previous link to a personal demo workflow).
- Added this CHANGELOG.

No code changes vs. v0.3.0.

## [0.3.0] - 2026-05-05

### Added
- **PR-scope filter**: dashboard defaults to "PR-only" view (toggleable to "Everything"); preference persists in `localStorage`. Empty-state notes appear in each tab when the current PR has no relevant entries for that section.
- **Comment restructured**: markdown report split into `## Overall` and `## This PR` sections. The PR section reports diff coverage, file count, related test count and runtime, and the slowest related tests.
- **`simplecov_track_files` config option** (default `'{app,lib}/**/*.rb'`): filters the *Untested Hot Paths* insight so non-Ruby churn (locales, schema dumps) doesn't surface as "untested code".
- **Markdown size guard**: report.md is truncated at ~60 KB to stay under GitHub's PR-comment limit.

## [0.2.0] - 2026-05-04

### Added
- Documented diff-coverage semantics in the README (it answers "what % of *this branch's* changed lines are covered now," not a delta-vs-main).

### Fixed
- `untested_hot_paths` insight now respects the (then-implicit) Ruby-files filter — prior versions could surface YAML and SQL changes.

## [0.1.0] - 2026-05-04

Initial release.

### Highlights
- Single self-contained HTML dashboard combining SimpleCov coverage, FactoryProf, EventProf, RSpecDissect.
- Diff coverage tab with per-file table and uncovered-code viewer.
- Failures tab (conditional) with error details and test source.
- Coverage tab with inline Codecov-style line viewer (click row to expand).
- Performance tab: time distribution, file grouping, slowest tests, RSpecDissect, EventProf.
- Factory Health tab: usage ranking, cascade analysis, optimization suggestions.
- Insights tab: high-risk files, over-tested, false security, untested hot paths.
- Parallel CI support: `test_report:merge[pattern]` rake task to merge per-shard artifacts.
- Markdown export (`report.md`) for AI/code-review tool consumption.
- Resource-usage capture: peak RSS memory, CPU time.
