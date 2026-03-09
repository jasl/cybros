module RuntimeGovernance
  class DraftGovernorResolver
    def self.resolve!(entrypoint:, selected_model_ref:, execution_target: nil)
      new(
        entrypoint: entrypoint,
        selected_model_ref: selected_model_ref,
        execution_target: execution_target,
      ).resolve!
    end

    def self.apply!(draft:, entrypoint:, selected_model_ref:, execution_target: nil)
      new(
        entrypoint: entrypoint,
        selected_model_ref: selected_model_ref,
        execution_target: execution_target,
      ).apply!(draft: draft)
    end

    def initialize(entrypoint:, selected_model_ref:, execution_target: nil)
      @entrypoint = entrypoint
      @selected_model_ref = selected_model_ref.to_s
      @execution_target = execution_target
    end

    def resolve!
      provider_resolution = ProviderCredentialLimiter.resolve!(selected_model_ref: selected_model_ref)
      target = resolved_execution_target!

      {
        permission_mode: resolved_permission_mode,
        selected_model_ref: selected_model_ref,
        provider_credential: provider_resolution.fetch(:provider_credential),
        proposed_execution_target: target,
        runtime_governors: {
          "provider_limiter" => provider_resolution.fetch(:snapshot),
          "execution_capacity" => ExecutionCapacityResolver.resolve!(execution_target: target),
        },
      }
    end

    def apply!(draft:)
      resolved = resolve!
      draft.assign_attributes(
        permission_mode: resolved.fetch(:permission_mode),
        provider_credential: resolved.fetch(:provider_credential),
        proposed_execution_target: resolved.fetch(:proposed_execution_target),
        selected_model_ref: resolved.fetch(:selected_model_ref),
        runtime_governors: resolved.fetch(:runtime_governors),
      )
      draft
    end

    private

      attr_reader :entrypoint, :selected_model_ref, :execution_target

      def resolved_execution_target!
        return execution_target if execution_target.present?

        if entrypoint.respond_to?(:default_execution_target) && entrypoint.default_execution_target.present?
          return entrypoint.default_execution_target
        end

        if entrypoint.respond_to?(:execution_target) && entrypoint.execution_target.present?
          return entrypoint.execution_target
        end

        if entrypoint.respond_to?(:default_execution_target_id) && entrypoint.default_execution_target_id.present?
          return ExecutionTarget.find(entrypoint.default_execution_target_id)
        end

        if entrypoint.respond_to?(:execution_target_id) && entrypoint.execution_target_id.present?
          return ExecutionTarget.find(entrypoint.execution_target_id)
        end

        AgentCore::ValidationError.raise!(
          "Execution target is required for programmable execution.",
          code: "cybros.runtime_governance.execution_target_missing",
          details: {},
        )
      end

      def resolved_permission_mode
        mode = entrypoint.respond_to?(:permission_mode) ? entrypoint.permission_mode.to_s : ""
        mode.present? ? mode : "default"
      end
  end
end
