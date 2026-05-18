# Changelog

All notable changes to `test_report_kit` are documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

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
