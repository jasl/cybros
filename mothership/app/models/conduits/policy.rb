module Conduits
  class Policy < ApplicationRecord
    self.table_name = "conduits_policies"

    belongs_to :account, optional: true

    # Polymorphic scope — the entity this policy applies to.
    # nil scope_type = global default.
    belongs_to :scope, polymorphic: true, optional: true

    VALID_SCOPE_TYPES = [nil, "Account", "User", "Conduits::Facility"].freeze
    VALID_NET_MODES = %w[none allowlist unrestricted].freeze
    VALID_APPROVAL_VERDICTS = %w[skip needs_approval forbidden].freeze
    VALID_DEVICE_KEYS = %w[allowed denied approval_required].freeze
    MAX_PATH_ENTRIES = 100

    validates :name, presence: true
    validates :priority, numericality: { only_integer: true }
    validates :scope_type, inclusion: { in: VALID_SCOPE_TYPES }, allow_nil: true
    validate :validate_fs_structure
    validate :validate_net_structure
    validate :validate_approval_structure
    validate :validate_device_structure

    scope :active, -> { where(active: true) }
    scope :by_priority, -> { order(priority: :asc) }

    # Resolve the effective policy for a directive by merging the scope hierarchy:
    #   global (scope_type=nil) → Account → User → Facility
    #
    # Returns a hash with merged capabilities:
    #   { fs:, net:, secrets:, sandbox_profile_rules:, approval:, policy_ids: }
    def self.effective_for(directive)
      policies = find_applicable_policies(directive)

      return empty_result if policies.empty?

      merge_policies(policies)
    end

    class << self
      private

      def find_applicable_policies(directive)
        scope_conditions = build_scope_conditions(directive)

        active
          .where(account_id: [nil, directive.account_id])
          .where(scope_conditions)
          .by_priority
          .to_a
      end

      def build_scope_conditions(directive)
        # Match: global (nil scope), Account, User, Facility
        conditions = arel_table[:scope_type].eq(nil)
        conditions = conditions.or(
          arel_table[:scope_type].eq("Account").and(arel_table[:scope_id].eq(directive.account_id))
        )
        conditions = conditions.or(
          arel_table[:scope_type].eq("User").and(arel_table[:scope_id].eq(directive.requested_by_user_id))
        )
        conditions = conditions.or(
          arel_table[:scope_type].eq("Conduits::Facility").and(arel_table[:scope_id].eq(directive.facility_id))
        )
        conditions
      end

      def merge_policies(policies)
        result = empty_result
        result[:policy_ids] = policies.map(&:id)

        policies.each do |policy|
          merge_fs!(result, policy)
          merge_net!(result, policy)
          merge_secrets!(result, policy)
          merge_sandbox_profile_rules!(result, policy)
          merge_approval!(result, policy)
          merge_device!(result, policy)
        end

        result
      end

      # FS: restrictive ceiling (intersection)
      def merge_fs!(result, policy)
        return if policy.fs.blank?

        if result[:fs].empty?
          result[:fs] = policy.fs.deep_dup
        else
          result[:fs] = FsPolicyV1.intersect(result[:fs], policy.fs)
        end
      end

      # Net: restrictive ceiling — lower mode rank wins, allow lists intersect
      NET_MODE_RANK = { "none" => 0, "allowlist" => 1, "unrestricted" => 2 }.freeze

      def merge_net!(result, policy)
        return if policy.net.blank?

        if result[:net].empty?
          result[:net] = policy.net.deep_dup
          return
        end

        existing_rank = NET_MODE_RANK.fetch(result[:net]["mode"], 2)
        incoming_rank = NET_MODE_RANK.fetch(policy.net["mode"], 2)

        if incoming_rank < existing_rank
          # Incoming is more restrictive — take it entirely
          result[:net] = policy.net.deep_dup
        elsif incoming_rank == existing_rank && result[:net]["mode"] == "allowlist"
          # Same rank + both allowlist → intersect allow lists
          existing_allow = Set.new(Array(result[:net]["allow"]))
          incoming_allow = Set.new(Array(policy.net["allow"]))
          result[:net]["allow"] = (existing_allow & incoming_allow).to_a
        end
        # If incoming_rank > existing_rank, keep existing (already more restrictive)
      end

      # Secrets: priority replace (higher priority wins)
      def merge_secrets!(result, policy)
        return if policy.secrets.blank?

        # Policies are ordered by priority ASC — later ones have higher priority
        result[:secrets] = policy.secrets.deep_dup
      end

      # Sandbox profile rules: priority replace
      def merge_sandbox_profile_rules!(result, policy)
        return if policy.sandbox_profile_rules.blank?

        result[:sandbox_profile_rules] = policy.sandbox_profile_rules.deep_dup
      end

      # Approval: most restrictive wins per key
      APPROVAL_RANK = { "skip" => 0, "needs_approval" => 1, "forbidden" => 2 }.freeze

      def merge_approval!(result, policy)
        return if policy.approval.blank?

        policy.approval.each do |key, value|
          existing = result[:approval][key]
          if existing.nil? || APPROVAL_RANK.fetch(value.to_s, 0) > APPROVAL_RANK.fetch(existing.to_s, 0)
            result[:approval][key] = value
          end
        end
      end

      # Device: uses DevicePolicyV1 merge semantics (intersection for allowed, union for denied)
      def merge_device!(result, policy)
        return if policy.device.blank?

        device = policy.device
        if result[:device].empty?
          result[:device] = device.deep_dup
        else
          # allowed: intersection
          if device["allowed"].present?
            result[:device]["allowed"] = if result[:device]["allowed"].nil?
              Array(device["allowed"])
            else
              DevicePolicyV1.send(:intersect_patterns,
                Array(result[:device]["allowed"]),
                Array(device["allowed"]))
            end
          end

          # denied: union
          result[:device]["denied"] = (Array(result[:device]["denied"]) | Array(device["denied"])) if device["denied"].present?

          # approval_required: union
          result[:device]["approval_required"] = (Array(result[:device]["approval_required"]) | Array(device["approval_required"])) if device["approval_required"].present?
        end
      end

      def empty_result
        {
          fs: {},
          net: {},
          secrets: {},
          sandbox_profile_rules: {},
          approval: {},
          device: {},
          policy_ids: [],
        }
      end
    end

    private

    def validate_fs_structure
      return if fs.blank?

      unless fs.is_a?(Hash)
        errors.add(:fs, "must be a hash")
        return
      end

      extra_keys = fs.keys - %w[read write]
      errors.add(:fs, "contains unknown keys: #{extra_keys.join(", ")}") if extra_keys.any?

      %w[read write].each do |key|
        next unless fs.key?(key)

        unless fs[key].is_a?(Array) && fs[key].all? { |v| v.is_a?(String) }
          errors.add(:fs, "#{key} must be an array of strings")
          next
        end

        if fs[key].length > MAX_PATH_ENTRIES
          errors.add(:fs, "#{key} cannot exceed #{MAX_PATH_ENTRIES} entries")
        end
      end
    end

    def validate_net_structure
      return if net.blank?

      unless net.is_a?(Hash)
        errors.add(:net, "must be a hash")
        return
      end

      if net.key?("mode") && !VALID_NET_MODES.include?(net["mode"])
        errors.add(:net, "mode must be one of: #{VALID_NET_MODES.join(", ")}")
      end
    end

    def validate_approval_structure
      return if approval.blank?

      unless approval.is_a?(Hash)
        errors.add(:approval, "must be a hash")
        return
      end

      approval.each do |key, value|
        unless VALID_APPROVAL_VERDICTS.include?(value.to_s)
          errors.add(:approval, "#{key} must be one of: #{VALID_APPROVAL_VERDICTS.join(", ")}")
        end
      end
    end

    def validate_device_structure
      return if device.blank?

      unless device.is_a?(Hash)
        errors.add(:device, "must be a hash")
        return
      end

      extra_keys = device.keys - VALID_DEVICE_KEYS
      errors.add(:device, "contains unknown keys: #{extra_keys.join(", ")}") if extra_keys.any?

      VALID_DEVICE_KEYS.each do |key|
        next unless device.key?(key)

        unless device[key].is_a?(Array) && device[key].all? { |v| v.is_a?(String) }
          errors.add(:device, "#{key} must be an array of strings")
        end
      end
    end
  end
end
