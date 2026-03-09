module System
  module Settings
    class ExecutionLocationsController < BaseController
      before_action :set_execution_location, only: %i[show edit update]
      before_action :set_form_inputs, only: :edit

      def index
        @execution_locations = ExecutionLocation.order(:name, :id)
      end

      def show
        @execution_targets = @execution_location.execution_targets.includes(:workspace).order(:name, :id)
        @workspaces = @execution_location.workspaces.order(:name, :id)
      end

      def edit
      end

      def update
        attributes, errors = execution_location_attributes_and_errors_from_params

        @execution_location.assign_attributes(attributes)
        errors.each { |field, message| @execution_location.errors.add(field, message) }
        set_form_inputs_from_params

        if errors.any? || !@execution_location.save
          render :edit, status: :unprocessable_entity
          return
        end

        flash[:notice] = "Execution location updated"
        redirect_to system_settings_execution_location_path(@execution_location)
      end

      private

        def set_execution_location
          @execution_location = ExecutionLocation.find(params[:id])
        end

        def set_form_inputs
          @max_concurrent_tasks_input = @execution_location.max_concurrent_tasks.to_s
          @max_queued_tasks_input = @execution_location.max_queued_tasks.to_s
          @default_timeout_s_input = @execution_location.default_timeout_s.to_s
        end

        def set_form_inputs_from_params
          @max_concurrent_tasks_input = execution_location_params.fetch(:max_concurrent_tasks, nil).to_s
          @max_queued_tasks_input = execution_location_params.fetch(:max_queued_tasks, nil).to_s
          @default_timeout_s_input = execution_location_params.fetch(:default_timeout_s, nil).to_s
        end

        def execution_location_attributes_and_errors_from_params
          raw = execution_location_params.permit(:max_concurrent_tasks, :max_queued_tasks, :default_timeout_s)
          attributes = {}
          errors = []

          attributes["max_concurrent_tasks"] = parse_positive_integer(raw[:max_concurrent_tasks], field: :max_concurrent_tasks, errors: errors)
          attributes["max_queued_tasks"] = parse_positive_integer(raw[:max_queued_tasks], field: :max_queued_tasks, errors: errors)
          attributes["default_timeout_s"] = parse_positive_integer(raw[:default_timeout_s], field: :default_timeout_s, errors: errors)

          [attributes.symbolize_keys, errors]
        end

        def parse_positive_integer(raw_value, field:, errors:)
          value = Integer(raw_value.to_s, exception: false)
          return value if value.present? && value.positive?

          errors << [field, "must be a positive integer"]
          nil
        end

        def execution_location_params
          params.fetch(:execution_location, ActionController::Parameters.new)
        end
    end
  end
end
