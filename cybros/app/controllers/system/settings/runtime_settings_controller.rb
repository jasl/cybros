module System
  module Settings
    class RuntimeSettingsController < BaseController
      before_action :set_runtime_setting
      before_action :set_form_payloads, only: :edit

      def show
      end

      def edit
      end

      def update
        attributes, errors = runtime_setting_attributes_and_errors_from_params

        @runtime_setting.assign_attributes(attributes)
        errors.each { |field, message| @runtime_setting.errors.add(field, message) }
        set_form_payloads_from_params

        if errors.any? || !@runtime_setting.save
          render :edit, status: :unprocessable_entity
          return
        end

        flash[:notice] = "Runtime settings updated"
        redirect_to system_settings_runtime_settings_path
      end

      private

        def set_runtime_setting
          @runtime_setting =
            RuntimeSetting.find_by(scope_key: "instance") ||
              RuntimeSetting.new(
                scope_key: "instance",
                default_worker_concurrency: RuntimeSetting::DEFAULT_WORKER_CONCURRENCY,
                queue_overrides: {},
                alert_thresholds: {},
                agent_workspace_root: RuntimeSetting.default_agent_workspace_root,
              )
        end

        def set_form_payloads
          @default_worker_concurrency_input = @runtime_setting.default_worker_concurrency.to_s
          @agent_workspace_root_input = @runtime_setting.agent_workspace_root.to_s
          @queue_overrides_json = format_json_object(@runtime_setting.queue_overrides)
          @alert_thresholds_json = format_json_object(@runtime_setting.alert_thresholds)
        end

        def set_form_payloads_from_params
          @default_worker_concurrency_input = runtime_setting_params.fetch(:default_worker_concurrency, nil).to_s
          @agent_workspace_root_input = runtime_setting_params.fetch(:agent_workspace_root, nil).to_s
          @queue_overrides_json = runtime_setting_params.fetch(:queue_overrides_json, nil).to_s
          @alert_thresholds_json = runtime_setting_params.fetch(:alert_thresholds_json, nil).to_s
        end

        def runtime_setting_attributes_and_errors_from_params
          raw = runtime_setting_params.permit(:default_worker_concurrency, :agent_workspace_root, :queue_overrides_json, :alert_thresholds_json)
          attributes = {}
          errors = []

          default_worker_concurrency = Integer(raw[:default_worker_concurrency].to_s, exception: false)
          if default_worker_concurrency.present? && default_worker_concurrency.positive?
            attributes["default_worker_concurrency"] = default_worker_concurrency
          else
            errors << [:default_worker_concurrency, "must be a positive integer"]
          end

          agent_workspace_root = raw[:agent_workspace_root].to_s.strip
          if agent_workspace_root.present?
            attributes["agent_workspace_root"] = agent_workspace_root
          else
            errors << [:agent_workspace_root, "can't be blank"]
          end

          attributes["queue_overrides"] = parse_json_object(raw[:queue_overrides_json], field: :queue_overrides, errors: errors)
          attributes["alert_thresholds"] = parse_json_object(raw[:alert_thresholds_json], field: :alert_thresholds, errors: errors)

          [attributes.symbolize_keys, errors]
        end

        def parse_json_object(raw_value, field:, errors:)
          parsed = JSON.parse(raw_value.to_s)
          return parsed if parsed.is_a?(Hash)

          errors << [field, "must be a JSON object"]
          {}
        rescue JSON::ParserError
          errors << [field, "must be a JSON object"]
          {}
        end

        def format_json_object(value)
          JSON.pretty_generate(value.presence || {})
        end

        def runtime_setting_params
          params.fetch(:runtime_setting, ActionController::Parameters.new)
        end
    end
  end
end
