class AgentProgramsController < AgentController
  before_action :set_agent_program, only: %i[show]
  before_action :require_operator_access

  def index
    redirect_to system_settings_agent_programs_path
  end

  def show
    redirect_to system_settings_agent_program_path(@agent_program)
  end

  private

    def require_operator_access
      return if Current.user&.owner? || Current.user&.admin?

      head :forbidden
    end

    def set_agent_program
      @agent_program = AgentProgram.find(params[:id])
    end
end
