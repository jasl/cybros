module Conduits
  module DevicePolicyV1
    Result = Data.define(:verdict, :reason)

    # Evaluate whether a capability is allowed given a set of policies.
    #
    # @param capability [String] e.g. "camera.snap"
    # @param policies [Array<Conduits::Policy>] ordered by priority ASC
    # @return [Result] verdict: :allowed | :denied | :needs_approval
    def self.evaluate(capability, policies)
      merged = merge_policies(policies)

      if matches_any?(capability, merged[:denied])
        return Result.new(verdict: :denied, reason: "explicitly denied")
      end

      unless matches_any?(capability, merged[:allowed])
        return Result.new(verdict: :denied, reason: "not in allowed list")
      end

      if matches_any?(capability, merged[:approval_required])
        return Result.new(verdict: :needs_approval, reason: "approval required")
      end

      Result.new(verdict: :allowed, reason: nil)
    end

    # Check whether a capability matches any pattern in the list.
    # Supports:
    #   - exact match: "camera.snap" == "camera.snap"
    #   - wildcard: "camera.*" matches "camera.snap", "camera.record"
    #   - global wildcard: "*" matches everything
    def self.matches_any?(capability, patterns)
      return false if patterns.nil? || patterns.empty?

      patterns.any? do |pattern|
        if pattern == "*"
          true
        elsif pattern.end_with?(".*")
          capability.start_with?(pattern.delete_suffix(".*") + ".")
        else
          capability == pattern
        end
      end
    end

    # Merge device policy sections from multiple policies using restrictive-ceiling semantics.
    #
    # - allowed: intersection (both levels must allow)
    # - denied: union (any level can deny)
    # - approval_required: union (any level can require approval)
    # - denied takes precedence over allowed
    def self.merge_policies(policies)
      result = { allowed: nil, denied: [], approval_required: [] }

      policies.sort_by(&:priority).each do |policy|
        device = policy.device
        device = {} if device.blank?
        device = device.with_indifferent_access if device.is_a?(Hash)

        if device["allowed"].present?
          result[:allowed] = if result[:allowed].nil?
            Array(device["allowed"])
          else
            intersect_patterns(result[:allowed], Array(device["allowed"]))
          end
        end

        result[:denied] |= Array(device["denied"])
        result[:approval_required] |= Array(device["approval_required"])
      end

      # If no allowed declaration exists, default to deny-all
      result[:allowed] ||= []
      result
    end

    # Intersect two pattern lists. A capability passes intersection only
    # if it could match in BOTH lists. For simplicity, we keep only
    # patterns that appear in both (exact match) or where one is a
    # wildcard that covers the other.
    def self.intersect_patterns(list_a, list_b)
      result = []

      # Keep exact matches that exist in both
      (list_a & list_b).each { |p| result << p }

      # For each pattern in list_a, check if any wildcard in list_b covers it
      list_a.each do |pa|
        next if result.include?(pa)
        result << pa if list_b.any? { |pb| pattern_covers?(pb, pa) }
      end

      # Vice versa
      list_b.each do |pb|
        next if result.include?(pb)
        result << pb if list_a.any? { |pa| pattern_covers?(pa, pb) }
      end

      result.uniq
    end

    # Returns true if `wide` pattern covers `narrow` pattern.
    # "*" covers everything; "camera.*" covers "camera.snap" and "camera.*"
    def self.pattern_covers?(wide, narrow)
      return true if wide == "*"
      return false unless wide.end_with?(".*")

      prefix = wide.delete_suffix(".*") + "."
      narrow.start_with?(prefix) || narrow == wide
    end

    private_class_method :intersect_patterns, :pattern_covers?
  end
end
