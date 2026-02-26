module Conduits
  # Orchestrates the full policy evaluation pipeline for a directive:
  #   1. Resolve hierarchical policies via Policy.effective_for
  #   2. Apply requested capabilities as bounds (can narrow, not widen)
  #   3. Run approval evaluation
  #   4. Return a frozen Result
  class PolicyResolver
    Result = Data.define(
      :effective_capabilities,  # merged hash
      :policy_snapshot,         # frozen for audit
      :approval_verdict,        # :skip / :needs_approval / :forbidden
      :approval_reasons,        # array of strings
      :policies_applied         # array of policy IDs
    )

    def initialize(directive)
      @directive = directive
    end

    def call
      resolved = Policy.effective_for(@directive)
      effective = build_effective_capabilities(resolved)

      approval = ApprovalEvaluator.new(
        effective_capabilities: effective,
        approval_rules: resolved[:approval],
        sandbox_profile: @directive.sandbox_profile
      ).evaluate

      Result.new(
        effective_capabilities: effective,
        policy_snapshot: build_snapshot(resolved),
        approval_verdict: approval.verdict,
        approval_reasons: approval.reasons,
        policies_applied: resolved[:policy_ids]
      )
    end

    private

    def build_effective_capabilities(resolved)
      requested = @directive.requested_capabilities || {}

      # Start with defaults for this profile
      defaults = DefaultCapabilities.fs_for(@directive.sandbox_profile)

      # Base FS: use policy ceiling if policies set it, else defaults
      base_fs = resolved[:fs].present? ? resolved[:fs] : defaults

      # Apply requested FS as narrowing bound
      effective_fs = if requested["fs"].present?
        FsPolicyV1.intersect(base_fs, requested["fs"])
      else
        base_fs
      end

      # Base net: use policy ceiling if set
      effective_net = apply_net_ceiling(resolved[:net], requested["net"])

      {
        "fs" => effective_fs,
        "net" => effective_net,
        "secrets" => resolved[:secrets].presence || {},
        "sandbox_profile_rules" => resolved[:sandbox_profile_rules],
      }
    end

    def apply_net_ceiling(policy_net, requested_net)
      return policy_net if policy_net.present? && requested_net.blank?
      return requested_net || {} if policy_net.blank?

      # Both present — take more restrictive mode
      policy_rank = net_mode_rank(policy_net["mode"])
      requested_rank = net_mode_rank(requested_net["mode"])

      if requested_rank <= policy_rank
        # Requested is same or more restrictive — use it
        requested_net
      else
        # Requested is less restrictive — cap to policy
        policy_net
      end
    end

    def net_mode_rank(mode)
      { "none" => 0, "allowlist" => 1, "unrestricted" => 2 }.fetch(mode.to_s, 2)
    end

    def build_snapshot(resolved)
      {
        "policies_applied" => resolved[:policy_ids],
        "resolved_at" => Time.current.iso8601,
        "fs" => resolved[:fs],
        "net" => resolved[:net],
        "secrets" => resolved[:secrets],
        "sandbox_profile_rules" => resolved[:sandbox_profile_rules],
        "approval" => resolved[:approval],
      }
    end
  end
end
