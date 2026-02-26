class DashboardController < AgentController
  def show
    @recent_conversations = Current.user.conversations.order(created_at: :desc).limit(10)
    @agent_program_count = AgentProgram.count
    @provider_count = LLMProvider.count

    runs_scope = ConversationRun.joins(:conversation).where(conversations: { user_id: Current.user.id })
    @run_state_counts = runs_scope.group(:state).count
    @last_run = runs_scope.order(created_at: :desc).first
  end
end
