module Conduits
  # Codex-style 3-tier approval evaluator.
  #
  # Evaluates effective capabilities against approval rules to produce
  # a verdict: :skip (auto-approved), :needs_approval, or :forbidden.
  #
  # Merge rule: forbidden > needs_approval > skip (most restrictive wins).
  class ApprovalEvaluator
    Result = Data.define(:verdict, :reasons)

    VERDICT_RANK = { skip: 0, needs_approval: 1, forbidden: 2 }.freeze

    def initialize(effective_capabilities:, approval_rules:, sandbox_profile:)
      @caps = effective_capabilities || {}
      @rules = approval_rules || {}
      @profile = sandbox_profile.to_s
    end

    def evaluate
      checks = []

      check_host_profile(checks)
      check_net_unrestricted(checks)
      check_fs_outside_workspace(checks)

      worst = worst_verdict(checks)
      reasons = checks.select { |c| c[:verdict] != :skip }.map { |c| c[:reason] }

      Result.new(verdict: worst, reasons: reasons)
    end

    private

    def check_host_profile(checks)
      rule = @rules["host_profile"]
      return unless rule

      if @profile == "host"
        checks << { verdict: rule.to_sym, reason: "host profile requires: #{rule}" }
      end
    end

    def check_net_unrestricted(checks)
      rule = @rules["net_unrestricted"]
      return unless rule

      net_mode = @caps.dig("net", "mode").to_s
      if net_mode == "unrestricted"
        checks << { verdict: rule.to_sym, reason: "unrestricted network requires: #{rule}" }
      end
    end

    def check_fs_outside_workspace(checks)
      rule = @rules["fs_outside_workspace"]
      return unless rule

      write_paths = Array(@caps.dig("fs", "write"))
      # FsPolicyV1.normalize_path always ensures a leading "/", so we only
      # need to check against "/workspace" (not bare "workspace").
      outside = write_paths.any? do |path|
        norm = FsPolicyV1.normalize_path(path)
        norm != "/workspace" && !norm.start_with?("/workspace/")
      end

      if outside
        checks << { verdict: rule.to_sym, reason: "filesystem access outside workspace requires: #{rule}" }
      end
    end

    def worst_verdict(checks)
      return :skip if checks.empty?

      checks.map { |c| c[:verdict] }
            .max_by { |v| VERDICT_RANK.fetch(v, 0) }
    end
  end
end
