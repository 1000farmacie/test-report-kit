# frozen_string_literal: true

require "spec_helper"
require "test_report_kit/diff_coverage"

RSpec.describe TestReportKit::DiffCoverage do
  let(:config) do
    TestReportKit.configure do |c|
      c.project_root = "/app"
      c.diff_base_branch = "main"
      c.diff_coverage_threshold = 90
    end
    TestReportKit.configuration
  end

  let(:coverage_data) do
    {
      "/app/app/services/cart_optimizer.rb" => {
        "lines" => [1, 1, nil, 1, 0, 1, nil, nil, nil, 1, 1, nil, nil, 1, 0, nil, nil, nil, nil, nil, nil, nil, nil, nil, 0, 0, 0, nil, nil]
      },
      "/app/app/models/order.rb" => {
        "lines" => [1, 1, 1, nil, 1, 0, 0, nil, 1, nil]
      }
    }
  end

  let(:diff_coverage) { described_class.new(coverage_data: coverage_data, config: config) }

  describe "#parse_git_diff" do
    let(:patch) { File.read(File.join(FIXTURES_PATH, "sample.patch")) }

    it "extracts changed lines from Ruby app/ and lib/ files only" do
      result = diff_coverage.parse_git_diff(patch)

      expect(result.keys).to contain_exactly(
        "app/services/cart_optimizer.rb",
        "app/models/order.rb",
        "app/services/pricing_engine.rb"
      )
    end

    it "skips spec files, config files, and non-Ruby files" do
      result = diff_coverage.parse_git_diff(patch)

      expect(result.keys).not_to include("spec/models/order_spec.rb")
      expect(result.keys).not_to include("config/routes.rb")
      expect(result.keys).not_to include("README.md")
    end

    it "parses hunk headers with count" do
      result = diff_coverage.parse_git_diff(patch)

      # cart_optimizer: @@ -3,0 +4,3 @@ → lines 4,5,6
      expect(result["app/services/cart_optimizer.rb"]).to include(4, 5, 6)
    end

    it "parses hunk headers with count=1 (replacement)" do
      result = diff_coverage.parse_git_diff(patch)

      # cart_optimizer: @@ -10,1 +14,1 @@ → line 14
      expect(result["app/services/cart_optimizer.rb"]).to include(14)
    end

    it "parses multi-line additions" do
      result = diff_coverage.parse_git_diff(patch)

      # cart_optimizer: @@ -20,0 +25,4 @@ → lines 25,26,27,28
      expect(result["app/services/cart_optimizer.rb"]).to include(25, 26, 27, 28)
    end

    it "handles new files (all lines are additions)" do
      result = diff_coverage.parse_git_diff(patch)

      # pricing_engine: @@ -0,0 +1,5 @@ → lines 1,2,3,4,5
      expect(result["app/services/pricing_engine.rb"]).to eq([1, 2, 3, 4, 5])
    end

    it "handles empty diff" do
      result = diff_coverage.parse_git_diff("")
      expect(result).to be_empty
    end

    it "handles diff with only deleted lines" do
      patch_delete = <<~PATCH
        diff --git a/app/models/user.rb b/app/models/user.rb
        index aaa..bbb 100644
        --- a/app/models/user.rb
        +++ b/app/models/user.rb
        @@ -5,2 +5,0 @@
      PATCH
      result = diff_coverage.parse_git_diff(patch_delete)
      expect(result).to be_empty
    end
  end

  describe "#call" do
    before do
      allow(diff_coverage).to receive(:run_git_diff).and_return(
        File.read(File.join(FIXTURES_PATH, "sample.patch"))
      )
      allow(diff_coverage).to receive(:git_merge_base).and_return("abc1234")
      allow(diff_coverage).to receive(:git_head_sha).and_return("def5678")
    end

    it "returns a Result struct" do
      result = diff_coverage.call
      expect(result).to be_a(TestReportKit::DiffCoverage::Result)
    end

    it "computes overall diff coverage" do
      result = diff_coverage.call
      expect(result.total_changed_lines).to be > 0
      expect(result.executable_changed_lines).to be > 0
      expect(result.covered_changed_lines).to be >= 0
      expect(result.diff_coverage_pct).to be_a(Float)
    end

    it "cross-references coverage correctly for cart_optimizer" do
      result = diff_coverage.call
      cart = result.files.find { |f| f.path == "app/services/cart_optimizer.rb" }

      # Lines 4,5,6,14,25,26,27,28 are changed
      # Line 4 → coverage[3] = 1 (covered)
      # Line 5 → coverage[4] = 0 (uncovered)
      # Line 6 → coverage[5] = 1 (covered)
      # Line 14 → coverage[13] = 1 (covered)
      # Line 25 → coverage[24] = 0 (uncovered)
      # Line 26 → coverage[25] = 0 (uncovered)
      # Line 27 → coverage[26] = 0 (uncovered)
      # Line 28 → coverage[27] = nil (non-executable)
      expect(cart.covered_lines).to contain_exactly(4, 6, 14)
      expect(cart.uncovered_lines).to contain_exactly(5, 25, 26, 27)
      expect(cart.non_executable_lines).to contain_exactly(28)
    end

    it "cross-references coverage correctly for order" do
      result = diff_coverage.call
      order = result.files.find { |f| f.path == "app/models/order.rb" }

      # Lines 6,7 are changed
      # Line 6 → coverage[5] = 0 (uncovered)
      # Line 7 → coverage[6] = 0 (uncovered)
      expect(order.covered_lines).to be_empty
      expect(order.uncovered_lines).to contain_exactly(6, 7)
    end

    it "marks files not in SimpleCov as not_loaded" do
      result = diff_coverage.call
      pricing = result.files.find { |f| f.path == "app/services/pricing_engine.rb" }

      expect(pricing.not_loaded).to be true
      expect(pricing.uncovered_lines).to eq([1, 2, 3, 4, 5])
      expect(pricing.diff_coverage_pct).to eq(0.0)
    end

    it "computes threshold pass/fail" do
      result = diff_coverage.call
      # With many uncovered lines, should be below 90% threshold
      expect(result.passed).to be false
      expect(result.threshold).to eq(90)
    end

    it "sorts files by coverage ascending (worst first)" do
      result = diff_coverage.call
      pcts = result.files.map(&:diff_coverage_pct)
      expect(pcts).to eq(pcts.sort)
    end

    it "returns nil for empty diff" do
      allow(diff_coverage).to receive(:run_git_diff).and_return("")
      expect(diff_coverage.call).to be_nil
    end

    it "returns nil when git diff fails" do
      allow(diff_coverage).to receive(:run_git_diff).and_return(nil)
      expect(diff_coverage.call).to be_nil
    end

    it "includes base/head sha info" do
      result = diff_coverage.call
      expect(result.base_branch).to eq("main")
      expect(result.base_sha).to eq("abc1234")
      expect(result.head_sha).to eq("def5678")
    end
  end

  describe "legacy SimpleCov format (array instead of hash)" do
    let(:coverage_data) do
      {
        "/app/app/services/cart_optimizer.rb" => [1, 1, nil, 1, 0, 1, nil, nil, nil, 1, 1, nil, nil, 1, 0, nil, nil, nil, nil, nil, nil, nil, nil, nil, 0, 0, 0, nil, nil],
        "/app/app/models/order.rb" => [1, 1, 1, nil, 1, 0, 0, nil, 1, nil]
      }
    end

    before do
      allow(diff_coverage).to receive(:run_git_diff).and_return(
        File.read(File.join(FIXTURES_PATH, "sample.patch"))
      )
      allow(diff_coverage).to receive(:git_merge_base).and_return("abc1234")
      allow(diff_coverage).to receive(:git_head_sha).and_return("def5678")
    end

    it "handles array-format coverage data" do
      result = diff_coverage.call
      cart = result.files.find { |f| f.path == "app/services/cart_optimizer.rb" }
      expect(cart.covered_lines).to contain_exactly(4, 6, 14)
    end
  end

  describe "git argument safety" do
    # Git refname rules permit `;`, `|`, `&` and `$()` (and `${IFS}` works around the
    # ban on spaces). Before argv-form calls, `diff_base_branch` was interpolated into
    # a backtick string, so any ref that came from ENV, YAML or a CI variable rather
    # than a literal executed as a shell command.
    let(:malicious_refs) do
      [
        "main; touch /tmp/pwned",
        "main && touch /tmp/pwned",
        "main | touch /tmp/pwned",
        "main$(touch /tmp/pwned)",
        "main`touch /tmp/pwned`",
        "--upload-pack=touch /tmp/pwned",
        "main\ntouch /tmp/pwned"
      ]
    end

    let(:evil_config) do
      TestReportKit.configure do |c|
        c.project_root = "/app"
        c.diff_base_branch = "main; touch /tmp/trk_pwned"
      end
      TestReportKit.configuration
    end

    let(:evil_diff_coverage) { described_class.new(coverage_data: coverage_data, config: evil_config) }

    it "rejects every shell metacharacter payload without spawning a process" do
      # Asserting only `be_nil` would be vacuous: in a checkout where neither `main`
      # nor `origin/main` resolves, the OLD vulnerable code also returned nil — while
      # still executing the payload. The load-bearing assertion is that git is never
      # invoked at all, which is environment-independent.
      aggregate_failures do
        malicious_refs.each do |ref|
          TestReportKit.configure do |c|
            c.project_root = "/app"
            c.diff_base_branch = ref
          end
          subject = described_class.new(coverage_data: coverage_data, config: TestReportKit.configuration)
          allow(Open3).to receive(:capture3)

          expect { subject.send(:resolve_base_ref) }.to output(/not a usable branch name/).to_stderr
          expect(Open3).not_to have_received(:capture3), "expected #{ref.inspect} to never reach git"
        end
      end
    end

    it "accepts ordinary refs including slashes, dots and dashes" do
      aggregate_failures do
        ["main", "develop", "release/2.1", "feature/foo-bar", "v1.0.0", "origin/main",
           "développement", "主分支", "fix+plus", "_private"].each do |ref|
          TestReportKit.configure do |c|
            c.project_root = "/app"
            c.diff_base_branch = ref
          end
          subject = described_class.new(coverage_data: coverage_data, config: TestReportKit.configuration)
          allow(subject).to receive(:git_capture).and_return("abcdef0123456789\n")
          expect(subject.send(:resolve_base_ref)).to eq("abcdef012345"), "expected #{ref.inspect} to be allowed"
        end
      end
    end

    it "skips diff coverage instead of raising on a non-UTF-8 ref" do
      # `call` is unrescued in Runner, so an encoding error here would abort the
      # entire report rather than degrade to "no diff coverage".
      TestReportKit.configure do |c|
        c.project_root = "/app"
        c.diff_base_branch = "main\xFF".dup.force_encoding("ASCII-8BIT")
      end
      subject = described_class.new(coverage_data: coverage_data, config: TestReportKit.configuration)

      expect { expect(subject.send(:resolve_base_ref)).to be_nil }
        .to output(/not a usable branch name/).to_stderr
    end

    it "does not mutate the configured branch string's encoding" do
      original = "main".dup.force_encoding("ASCII-8BIT")
      TestReportKit.configure do |c|
        c.project_root = "/app"
        c.diff_base_branch = original
      end
      subject = described_class.new(coverage_data: coverage_data, config: TestReportKit.configuration)
      allow(subject).to receive(:git_capture).and_return("abcdef0123456789\n")

      subject.send(:resolve_base_ref)
      expect(original.encoding.to_s).to eq("ASCII-8BIT")
    end

    it "passes each git argument separately so no shell parses them" do
      expect(Open3).to receive(:capture3)
        .with("git", "rev-parse", "--verify", "main")
        .and_return(["abcdef0123456789\n", "", instance_double(Process::Status, success?: true)])

      expect(diff_coverage.send(:resolve_base_ref)).to eq("abcdef012345")
    end

    it "returns nil rather than raising when git is absent" do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
      expect(diff_coverage.send(:git_capture, "rev-parse", "HEAD")).to be_nil
    end

    it "returns nil when git exits non-zero" do
      allow(Open3).to receive(:capture3)
        .and_return(["", "fatal: bad revision", instance_double(Process::Status, success?: false)])
      expect(diff_coverage.send(:git_capture, "rev-parse", "nope")).to be_nil
    end
  end
end
