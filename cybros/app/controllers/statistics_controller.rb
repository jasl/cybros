class StatisticsController < AgentController
  def show
    @stats = Cybros::Statistics::UsageStats.for_user(user: Current.user)
    @global_by_provider =
      if Current.user&.owner? || Current.user&.admin?
        Cybros::Statistics::UsageStats.global_by_provider_key
      end
  end
end
