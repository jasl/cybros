module RuntimeGovernance
  class DraftGovernorResolver
    def self.resolve!(entrypoint:, selected_model_ref:, permission_mode: nil)
      new(
        entrypoint: entrypoint,
        selected_model_ref: selected_model_ref,
        permission_mode: permission_mode,
      ).resolve!
    end

    def self.apply!(draft:, entrypoint:, selected_model_ref:, permission_mode: nil)
      new(
        entrypoint: entrypoint,
        selected_model_ref: selected_model_ref,
        permission_mode: permission_mode,
      ).apply!(draft: draft)
    end

    def initialize(entrypoint:, selected_model_ref:, permission_mode:)
      @entrypoint = entrypoint
      @selected_model_ref = selected_model_ref.to_s
      @permission_mode = permission_mode.to_s
    end

    def resolve!
      provider_resolution = ProviderCredentialLimiter.resolve!(selected_model_ref: selected_model_ref)
      agent = resolved_agent

      {
        permission_mode: resolved_permission_mode,
        selected_model_ref: selected_model_ref,
        provider_credential: provider_resolution.fetch(:provider_credential),
        runtime_governors: {
          "provider_limiter" => provider_resolution.fetch(:snapshot),
          "execution_capacity" => resolved_execution_capacity(agent: agent),
        }.compact,
      }
    end

    def apply!(draft:)
      resolved = resolve!
      draft.assign_attributes(
        permission_mode: resolved.fetch(:permission_mode),
        provider_credential: resolved.fetch(:provider_credential),
        agent: resolved_agent || draft.agent,
        selected_model_ref: resolved.fetch(:selected_model_ref),
        runtime_governors: resolved.fetch(:runtime_governors),
      )
      draft
    end

    private

      attr_reader :entrypoint, :selected_model_ref, :permission_mode

      def resolved_agent
        return entrypoint.agent if entrypoint.respond_to?(:agent) && entrypoint.agent.present?

        nil
      end

      def resolved_execution_capacity(agent:)
        return nil if agent.blank?

        ExecutionCapacityResolver.resolve!(agent: agent)
      end

      def resolved_permission_mode
        return permission_mode if permission_mode.present?

        mode = entrypoint.respond_to?(:permission_mode) ? entrypoint.permission_mode.to_s : ""
        mode.present? ? mode : "default"
      end
  end
end
