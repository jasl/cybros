module System
  module Settings
    class ExecutionTargetsController < BaseController
      before_action :set_execution_target, only: %i[show edit update]
      before_action :set_form_inputs, only: :edit

      def index
        @execution_targets = ExecutionTarget.includes(:execution_location, :workspace).order(:name, :id)
      end

      def show
      end

      def edit
      end

      def update
        attributes, errors = execution_target_attributes_and_errors_from_params

        @execution_target.assign_attributes(attributes)
        errors.each { |field, message| @execution_target.errors.add(field, message) }
        set_form_inputs_from_params

        if errors.any? || !@execution_target.save
          render :edit, status: :unprocessable_entity
          return
        end

        flash[:notice] = "Target overrides updated"
        redirect_to system_settings_execution_target_path(@execution_target)
      end

      private

        def set_execution_target
          @execution_target = ExecutionTarget.includes(:execution_location, :workspace).find(params[:id])
        end

        def set_form_inputs
          @max_concurrent_tasks_override_input = @execution_target.max_concurrent_tasks_override.to_s
          @max_queued_tasks_override_input = @execution_target.max_queued_tasks_override.to_s
          @default_timeout_s_override_input = @execution_target.default_timeout_s_override.to_s
        end

        def set_form_inputs_from_params
          @max_concurrent_tasks_override_input = execution_target_params.fetch(:max_concurrent_tasks_override, nil).to_s
          @max_queued_tasks_override_input = execution_target_params.fetch(:max_queued_tasks_override, nil).to_s
          @default_timeout_s_override_input = execution_target_params.fetch(:default_timeout_s_override, nil).to_s
        end

        def execution_target_attributes_and_errors_from_params
          raw =
            execution_target_params.permit(
              :max_concurrent_tasks_override,
              :max_queued_tasks_override,
              :default_timeout_s_override,
            )
          attributes = {}
          errors = []

          attributes["max_concurrent_tasks_override"] = parse_optional_positive_integer(raw[:max_concurrent_tasks_override], field: :max_concurrent_tasks_override, errors: errors)
          attributes["max_queued_tasks_override"] = parse_optional_positive_integer(raw[:max_queued_tasks_override], field: :max_queued_tasks_override, errors: errors)
          attributes["default_timeout_s_override"] = parse_optional_positive_integer(raw[:default_timeout_s_override], field: :default_timeout_s_override, errors: errors)

          [attributes.symbolize_keys, errors]
        end

        def parse_optional_positive_integer(raw_value, field:, errors:)
          text = raw_value.to_s.strip
          return nil if text.blank?

          value = Integer(text, exception: false)
          return value if value.present? && value.positive?

          errors << [field, "must be a positive integer"]
          nil
        end

        def execution_target_params
          params.fetch(:execution_target, ActionController::Parameters.new)
        end
    end
  end
end
