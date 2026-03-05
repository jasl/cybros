class DashboardController < AgentController
  def show
    @recent_conversations = Current.user.conversations.order(created_at: :desc).limit(10)
    @agent_program_count = AgentProgram.count
    providers = LLMProvider.all.to_a
    @provider_count = providers.size

    invalid_base_url = 0
    missing_api_key = 0
    allowlist_empty = 0
    allowlist_blank_entries = 0
    allowlist_duplicate_entries = 0

    providers.each do |p|
      begin
        url = URI.parse(p.base_url.to_s)
        invalid_base_url += 1 unless url.is_a?(URI::HTTP) || url.is_a?(URI::HTTPS)
      rescue URI::InvalidURIError
        invalid_base_url += 1
      end

      missing_api_key += 1 if p.api_key.to_s.strip.blank?

      allowlist = Array(p.model_allowlist).map { |v| v.to_s.strip }
      nonblank = allowlist.reject(&:blank?)
      allowlist_empty += 1 if nonblank.empty?
      allowlist_blank_entries += 1 if allowlist.any?(&:blank?)

      dup_count = nonblank.tally.count { |_k, v| v > 1 }
      allowlist_duplicate_entries += dup_count if dup_count > 0
    end

    @provider_health = {
      invalid_base_url: invalid_base_url,
      missing_api_key: missing_api_key,
      allowlist_empty: allowlist_empty,
      allowlist_blank_entries: allowlist_blank_entries,
      allowlist_duplicate_entries: allowlist_duplicate_entries,
    }

    runs_scope = ConversationRun.joins(:conversation).where(conversations: { user_id: Current.user.id })
    @run_state_counts = runs_scope.group(:state).count
    @last_run = runs_scope.order(created_at: :desc).first
  end
end
