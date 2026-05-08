# test_report_kit

RSpec coverage + profiling HTML dashboard. Reads SimpleCov and test-prof output files, generates a single self-contained HTML report.

## Setup

### From GitHub

```ruby
# Gemfile
group :test do
  gem "test_report_kit", github: "1000farmacie/test-report-kit", tag: "v0.3.1"
  gem "simplecov", require: false
  gem "simplecov-json", require: false
  gem "test-prof", "~> 1.0"
end
```

### From local path

If you have the gem checked out locally (e.g. at `~/projects/test_report_kit`):

```ruby
# Gemfile
group :test do
  gem "test_report_kit", path: "~/projects/test_report_kit"
  gem "simplecov", require: false
  gem "simplecov-json", require: false
  gem "test-prof", "~> 1.0"
end
```

### Configure

```ruby
# config/initializers/test_report_kit.rb
if Rails.env.test?
  TestReportKit.configure do |config|
    config.project_name = "my_app"
    config.github_url = "https://github.com/org/repo"
  end
end
```

### Run

```bash
bundle exec rake test_report:full
open tmp/test_report/index.html
```

Auto-integrates via Railtie. No manual require needed.

For non-Rails projects, add to your Rakefile:

```ruby
require "test_report_kit"
load "tasks/test_report_kit.rake"
```

## Rake Tasks

| Task | Description |
|------|-------------|
| `test_report:full` | Run tests with coverage + profiling, generate report |
| `test_report:coverage` | Coverage only (no profiling) |
| `test_report:profile` | Profiling only (no coverage) |
| `test_report:generate` | Re-generate from existing JSON (no test run) |
| `test_report:merge[pattern]` | Merge parallel CI artifacts and generate report |

## Dashboard Tabs

| Tab | Content |
|-----|---------|
| Diff Coverage | Changed lines coverage with uncovered code viewer |
| Failures | Failed tests with error details + source (conditional) |
| Coverage | Per-file coverage with inline line viewer (click to expand) |
| Performance | Time distribution, file grouping, slowest tests, RSpecDissect, EventProf |
| Factory Health | FactoryBot usage, cascade analysis, optimization suggestions |
| Insights | High-risk files, over-tested, false security, untested hot paths |
| Parallel | Per-node stats, efficiency %, duration balance (conditional, after merge) |

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `project_name` | dir name | Dashboard header |
| `output_dir` | `tmp/test_report` | Output directory |
| `diff_base_branch` | `main` | Git diff base |
| `coverage_threshold` | `80` | Coverage gate (%) |
| `diff_coverage_threshold` | `90` | Diff coverage gate (%) |
| `churn_days` | `90` | Git churn lookback (days) |
| `slow_test_threshold` | `5.0` | Slow test flag (seconds) |
| `github_url` | `nil` | Enables source links |
| `event_prof_event` | `factory.create` | EventProf event |
| `profilers` | `[:factory_prof, :rspec_dissect, :event_prof]` | Enabled profilers |
| `fail_on_coverage` | `false` | Exit 1 if below `coverage_threshold` |
| `fail_on_diff_coverage` | `false` | Exit 1 if below `diff_coverage_threshold` |

### What "diff coverage" means here

Diff coverage answers a single question: **of the lines you added or changed in this branch, what percentage are covered by the test suite running right now?**

What it is NOT:

- It is **not** a comparison against main's coverage.
- It does **not** read or store any baseline. Each run is independent.
- It does **not** show "+/- X% vs main" deltas (Codecov-style).

The base branch (`diff_base_branch`, default `main`) is used **only to compute the git diff** (which lines changed), never to fetch coverage data from main.

The gate (`fail_on_diff_coverage` + `diff_coverage_threshold`) enforces "every PR must cover ≥ N% of its own diff" — a stronger signal than absolute-coverage-didn't-drop, since it forces test discipline on the lines that actually changed.

If you want Codecov-style "vs main" deltas, persist `summary.json` from main runs (e.g. as a long-retention CI artifact) and diff it client-side against PR runs. The gem doesn't do this for you.

## Output Files

All written to `output_dir` (default `tmp/test_report/`):

| File | Purpose |
|------|---------|
| `index.html` | Dashboard (self-contained, open in browser) |
| `summary.json` | CI consumption (PR comments, threshold gates) |
| `report.md` | Markdown report with action items (for AI/code review tools) |
| `resource_usage.json` | Peak memory (MB), CPU time (user/system seconds) |
| `rspec_results.json` | Raw RSpec JSON output |
| `factory_prof.json` | FactoryProf data |
| `event_prof.json` | EventProf data |
| `rspec_dissect.json` | RSpecDissect data |
| `git_churn.json` | Per-file commit counts (last N days) |

## CI integration (sticky PR comment)

The recommended CI shape for matrix-based parallel test runs that posts a single sticky PR comment with the merged report. Two jobs: `rspec` (runs the matrix shards) and `report` (merges and comments).

```yaml
jobs:
  rspec:
    strategy:
      matrix:
        include:
          - shard: 0
            specs: "spec/models/ spec/jobs/"
          - shard: 1
            specs: "spec/services/"
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }   # diff coverage needs full history
      - uses: ruby/setup-ruby@v1
        with: { bundler-cache: true }
      - run: bundle exec rake test_report:full
        env:
          TEST_REPORT_SPECS: ${{ matrix.specs }}
          TEST_ENV_NUMBER: ${{ matrix.shard }}
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: test-results-${{ matrix.shard }}
          include-hidden-files: true   # required for SimpleCov's .resultset.json
          path: |
            coverage/
            tmp/test_report/
            tmp/test_prof/

  report:
    needs: rspec
    if: always()
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: ruby/setup-ruby@v1
        with: { bundler-cache: true }
      - uses: actions/download-artifact@v4
        with:
          path: artifacts
          pattern: test-results-*
      - run: bundle exec rake "test_report:merge[artifacts/test-results-*]"

      - name: Upload merged report
        id: upload
        uses: actions/upload-artifact@v4
        with:
          name: test-report
          path: tmp/test_report/
          include-hidden-files: true

      - name: Find PR number
        id: pr
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          BRANCH: ${{ github.head_ref || github.ref_name }}
        run: |
          number=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number // empty')
          echo "number=$number" >> "$GITHUB_OUTPUT"

      - name: Post sticky PR comment
        if: steps.pr.outputs.number != ''
        uses: marocchino/sticky-pull-request-comment@v2
        with:
          number: ${{ steps.pr.outputs.number }}
          header: test-report-kit
          path: tmp/test_report/report.md

      - name: Diagnose missing comment
        if: steps.pr.outputs.number == ''
        run: echo "::warning::No open PR found for branch ${{ github.head_ref || github.ref_name }} — skipping sticky comment."
```

Key points:

- `include-hidden-files: true` is mandatory — SimpleCov writes `.resultset.json` (leading dot) and `actions/upload-artifact@v4` skips dotfiles by default.
- `fetch-depth: 0` is required on both jobs — diff coverage walks the git history to compute the diff.
- The sticky comment uses the `header:` to dedupe; subsequent CI runs replace the previous comment in place rather than stacking.
- `TEST_ENV_NUMBER` becomes part of SimpleCov's `command_name` so per-shard `.resultset.json` files don't collide when merged.

## Architecture

Zero runtime deps on simplecov/test-prof. Reads their output files after RSpec completes.

```
Runner → shells out to rspec with ENV vars (FPROF, EVENT_PROF, RD_PROF)
       → DataLoader reads all JSON outputs
       → DiffCoverage parses git diff + cross-refs SimpleCov
       → MetricsCalculator computes risk scores + insights
       → Generator renders ERB templates → single HTML
       → SummaryExporter writes summary.json
       → MarkdownExporter writes report.md
```

## Development

```bash
git clone git@github.com:1000farmacie/test-report-kit.git
cd test-report-kit
docker compose build
docker compose run --rm gem bundle exec rspec   # 87 specs
```

MIT License
