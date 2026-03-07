class DashboardController < AgentController
  def show
    @recent_conversations = Current.user.conversations.order(created_at: :desc).limit(10)
    @agent_program_count = AgentProgram.count
    catalog = Cybros::LLM::Catalog.effective
    provider_keys = catalog.enabled_provider_keys_for_env(Rails.env)
    providers =
      provider_keys.map do |provider_key|
        spec = catalog.provider(provider_key)
        cred = LLMProvider.find_by(provider_key: provider_key)
        {
          provider_key: provider_key,
          spec: spec,
          credential: cred,
          has_credential: Cybros::AgentRuntimeResolver.send(:credential_present_for_provider?, provider_key: provider_key, provider_spec: spec),
        }
      end

    invalid_base_url = 0
    missing_credential = 0
    configured = 0

    providers.each do |p|
      spec = p.fetch(:spec)
      begin
        url = URI.parse(spec.fetch("base_url").to_s)
        invalid_base_url += 1 unless url.is_a?(URI::HTTP) || url.is_a?(URI::HTTPS)
      rescue URI::InvalidURIError
        invalid_base_url += 1
      end

      requires = spec.fetch("requires_credential") == true
      has_cred = p.fetch(:has_credential)

      configured += 1 if has_cred
      missing_credential += 1 if requires && !has_cred
    end

    @provider_count = configured
    @provider_health = {
      invalid_base_url: invalid_base_url,
      missing_credential: missing_credential,
    }

    runs_scope = ConversationRun.joins(:conversation).where(conversations: { user_id: Current.user.id })
    @run_state_counts = runs_scope.group(:state).count
    @last_run = runs_scope.order(created_at: :desc).first
  end
end
