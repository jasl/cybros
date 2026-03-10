module System
  module Settings
    class LLMProvidersController < BaseController
      before_action :set_provider_spec, only: %i[edit update device_flow_start device_flow_poll]
      before_action :set_llm_provider, only: %i[edit update]

      def index
        load_index_context
      end

      def default_model
        load_index_context
        model_ref = params.fetch(:default_model_ref, "").to_s.strip

        if model_ref.blank? && @catalog_default_unusable
          @default_model_error = "Catalog default is not currently usable."
          render :index, status: :unprocessable_entity
          return
        end

        if model_ref.present? && @default_model_options.none? { |option| option.fetch(:model_ref) == model_ref }
          @default_model_error = "Default model must be currently usable"
          render :index, status: :unprocessable_entity
          return
        end

        Account.instance.update_llm_default_model_ref!(model_ref)
        flash[:notice] = model_ref.present? ? "Default model updated" : "Default model cleared"
        redirect_to system_settings_llm_providers_path
      end

      def edit
        @device_flow = active_device_flow_for(@provider_key)
        @backoff_policy_json = format_backoff_policy(@llm_provider.backoff_policy)
      end

      def update
        @device_flow = active_device_flow_for(@provider_key)
        attrs, errors = credential_attributes_and_errors_from_params

        attrs.delete(:api_key) if attrs.key?(:api_key) && attrs[:api_key].to_s.strip == ""
        @backoff_policy_json = llm_provider_params.fetch(:backoff_policy_json, nil).to_s
        @backoff_policy_json = format_backoff_policy(@llm_provider.backoff_policy) if @backoff_policy_json.blank?

        if errors.any?
          @llm_provider.assign_attributes(attrs)
          errors.each { |(field, message)| @llm_provider.errors.add(field, message) }
          render :edit, status: :unprocessable_entity
          return
        end

        if @llm_provider.update(attrs)
          flash[:notice] = "Credentials updated"
          redirect_to edit_system_settings_llm_provider_path(@provider_key)
        else
          render :edit, status: :unprocessable_entity
        end
      end

      def device_flow_start
        return unless ensure_oauth_device_flow_supported!

        flow = Cybros::LLM::CodexOAuth.start_device_flow!
        session[:llm_device_flow] ||= {}
        session[:llm_device_flow][@provider_key] = flow.merge("session_id" => Current.session&.id.to_s)

        flash[:notice] = "Device flow started"
        redirect_to edit_system_settings_llm_provider_path(@provider_key)
      rescue Cybros::LLM::CodexOAuthError => e
        flash[:alert] = e.message
        redirect_to edit_system_settings_llm_provider_path(@provider_key)
      end

      def device_flow_poll
        return unless ensure_oauth_device_flow_supported!

        flow = active_device_flow_for(@provider_key)
        unless flow.is_a?(Hash) && flow["device_auth_id"].to_s.present? && flow["user_code"].to_s.present?
          flash[:alert] = "No active device flow. Start it first."
          redirect_to edit_system_settings_llm_provider_path(@provider_key)
          return
        end

        result =
          Cybros::LLM::CodexOAuth.poll_device_flow!(
            device_auth_id: flow.fetch("device_auth_id"),
            user_code: flow.fetch("user_code"),
          )
        status = result.fetch(:status)
        if status == :authorized
          tokens = result.fetch(:tokens)

          cred = LLMProviderCredential.find_by(provider_key: @provider_key) || LLMProviderCredential.new(provider_key: @provider_key, credential_type: "oauth_codex")
          cred.credential_type = "oauth_codex"
          cred.access_token = tokens.fetch("access_token")
          cred.refresh_token = tokens.fetch("refresh_token", cred.refresh_token)
          cred.expires_at = tokens.fetch("expires_at", nil)
          cred.account_id = tokens.fetch("account_id", cred.account_id)
          cred.save!

          (session[:llm_device_flow] || {}).delete(@provider_key)
          flash[:notice] = "Connected"
        elsif status == :pending
          flash[:notice] = "Waiting for authorization…"
        else
          flash[:alert] = "Device flow failed: #{result[:error] || status}"
        end

        redirect_to edit_system_settings_llm_provider_path(@provider_key)
      rescue Cybros::LLM::CodexOAuthError => e
        clear_device_flow_session!(@provider_key) if terminal_device_flow_error?(e)
        flash[:alert] = e.message
        redirect_to edit_system_settings_llm_provider_path(@provider_key)
      end

      private

        def set_provider_spec
          @catalog = Cybros::LLM::Catalog.effective
          @provider_key = params[:provider_key].to_s
          raise ActiveRecord::RecordNotFound if @provider_key.blank?
          raise ActiveRecord::RecordNotFound unless @catalog.enabled_provider_keys_for_env(Rails.env).include?(@provider_key)

          @provider_spec = @catalog.provider(@provider_key)
        rescue KeyError
          raise ActiveRecord::RecordNotFound
        end

        def set_llm_provider
          @llm_provider =
            LLMProviderCredential.find_by(provider_key: @provider_key) ||
              LLMProviderCredential.new(provider_key: @provider_key, credential_type: credential_type_from_spec, status: "active")
        end

        def credential_type_from_spec
          ct = @provider_spec.fetch("credential_type", nil).to_s.strip
          ct = "api_key" if ct.empty?
          ct
        end

        def ensure_oauth_device_flow_supported!
          unless @provider_spec.fetch("credential_type", nil).to_s == "oauth_codex"
            head :unprocessable_entity
            return false
          end
          true
        end

        def credential_attributes_and_errors_from_params
          ct = credential_type_from_spec
          raw =
            llm_provider_params.permit(
              :api_key,
              :max_concurrent_requests,
              :requests_per_minute,
              :tokens_per_minute,
              :burst_limit,
              :backoff_policy_json,
            )
          attrs = raw.except(:backoff_policy_json).to_h
          errors = []

          unless ct == "api_key"
            attrs.delete("api_key")
          end

          if raw.key?(:backoff_policy_json)
            backoff_policy_json = raw[:backoff_policy_json].to_s
            if backoff_policy_json.blank?
              attrs["backoff_policy"] = nil
            else
              parsed = parse_backoff_policy(backoff_policy_json)
              if parsed
                attrs["backoff_policy"] = parsed
              else
                errors << [:backoff_policy, "must be a JSON object"]
              end
            end
          end

          attrs["provider_key"] = @provider_key
          attrs["credential_type"] = ct

          [attrs.symbolize_keys, errors]
        end

        def parse_backoff_policy(raw_json)
          parsed = JSON.parse(raw_json)
          parsed if parsed.is_a?(Hash)
        rescue JSON::ParserError
          nil
        end

        def llm_provider_params
          params.fetch(:llm_provider, params.fetch(:llm_provider_credential, ActionController::Parameters.new))
        end

        def format_backoff_policy(policy)
          JSON.pretty_generate(policy.presence || {})
        end

        def load_index_context
          @catalog = Cybros::LLM::Catalog.effective
          provider_keys = @catalog.enabled_provider_keys_for_env(Rails.env)
          @providers =
            provider_keys.map do |provider_key|
              spec = @catalog.provider(provider_key)
              cred = LLMProviderCredential.find_by(provider_key: provider_key)
              {
                provider_key: provider_key,
                spec: spec,
                credential: cred,
                has_credential: Cybros::AgentRuntimeResolver.send(:credential_present_for_provider?, provider_key: provider_key, provider_spec: spec),
              }
            end

          @stored_default_model_ref = Account.instance.llm_default_model_ref
          @site_default_missing_from_catalog =
            @stored_default_model_ref.present? && !model_ref_in_catalog?(@stored_default_model_ref)
          @site_default_unusable = false
          if @stored_default_model_ref.present? && !@site_default_missing_from_catalog
            begin
              Cybros::AgentRuntimeResolver.validate_model_ref!(model_ref: @stored_default_model_ref)
            rescue AgentCore::ValidationError
              @site_default_unusable = true
            end
          end

          @catalog_default_model_ref = @catalog.default_model_ref
          @catalog_default_unusable = false
          begin
            Cybros::AgentRuntimeResolver.validate_model_ref!(model_ref: @catalog_default_model_ref)
          rescue AgentCore::ValidationError
            @catalog_default_unusable = true
          end
          @effective_default_model_ref = @site_default_missing_from_catalog ? @catalog_default_model_ref : (@stored_default_model_ref || @catalog_default_model_ref)
          @default_model_source_text =
            if @site_default_missing_from_catalog || @stored_default_model_ref.blank?
              "Catalog default: #{@catalog_default_model_ref}"
            else
              "Site override: #{@stored_default_model_ref}"
            end

          @default_model_options = Cybros::AgentRuntimeResolver.usable_model_options(catalog: @catalog)
        end

        def model_ref_in_catalog?(model_ref)
          provider_key, model_key = model_ref.to_s.split("/", 2).map(&:to_s)
          return false if provider_key.blank? || model_key.blank?

          @catalog.model(provider_key, model_key)
          true
        rescue KeyError
          false
        end

        def active_device_flow_for(provider_key)
          flows = session[:llm_device_flow]
          return nil unless flows.is_a?(Hash)

          flow = flows[provider_key.to_s]
          return nil unless flow.is_a?(Hash)
          return nil if flow["device_auth_id"].to_s.blank? || flow["user_code"].to_s.blank?

          stored_session_id = flow["session_id"].to_s
          current_session_id = Current.session&.id.to_s
          if stored_session_id.blank? || current_session_id.blank? || stored_session_id != current_session_id
            clear_device_flow_session!(provider_key)
            return nil
          end

          expires_at = parse_optional_time(flow["expires_at"])
          if expires_at.nil? || expires_at <= Time.current
            clear_device_flow_session!(provider_key)
            return nil
          end

          flow
        rescue StandardError
          nil
        end

        def parse_optional_time(value)
          string = value.to_s.strip
          return nil if string.empty?

          Time.iso8601(string)
        rescue ArgumentError
          nil
        end

        def clear_device_flow_session!(provider_key)
          flows = session[:llm_device_flow]
          return unless flows.is_a?(Hash)

          flows.delete(provider_key.to_s)
          session[:llm_device_flow] = flows
        end

        def terminal_device_flow_error?(error)
          return true if error.error_code.to_s.present?

          status = error.details.is_a?(Hash) ? error.details[:status] || error.details["status"] : nil
          [400, 401, 410].include?(status.to_i)
        rescue StandardError
          false
        end
    end
  end
end
