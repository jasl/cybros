module RuntimeGovernorSnapshotConsistency
  extend ActiveSupport::Concern

  included do
    validate :governor_snapshot_consistency
  end

  private

    def governor_snapshot_consistency
      provider_snapshot = runtime_governors["provider_limiter"]
      execution_snapshot = runtime_governors["execution_capacity"]

      if provider_credential_id.present? || selected_model_ref.present?
        unless provider_snapshot.is_a?(Hash)
          errors.add(:runtime_governors, "must include a provider_limiter snapshot")
          return
        end

        if provider_credential_id.present? && provider_snapshot["provider_credential_id"].to_s != provider_credential_id.to_s
          errors.add(:runtime_governors, "must snapshot the selected provider credential")
        end

        selected_provider_key = selected_model_ref.to_s.split("/", 2).first.to_s
        if selected_provider_key.present? && provider_snapshot["provider_key"].to_s != selected_provider_key
          errors.add(:runtime_governors, "must snapshot the selected model provider")
        end
      end

      if runtime_governor_agent_id.present?
        unless execution_snapshot.is_a?(Hash)
          errors.add(:runtime_governors, "must include an execution_capacity snapshot")
          return
        end

        if execution_snapshot["scope_type"].to_s != "agent" || execution_snapshot["scope_id"].to_s != runtime_governor_agent_id.to_s
          errors.add(:runtime_governors, "must snapshot the selected agent execution capacity policy")
        end
      end
    end

    def runtime_governor_agent_id
      return unless respond_to?(:agent_id)

      agent_id
    end
end
