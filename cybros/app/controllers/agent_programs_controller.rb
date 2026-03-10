class AgentProgramsController < AgentController
  before_action :set_agent_program, only: %i[show]

  def index
    @agent_programs = AgentProgram.order(created_at: :asc)
  end

  def new
    @bundled_sources = AgentPrograms::BundledSources.available_keys
  end

  def create
    name = params.dig(:agent_program, :name).to_s.strip
    bundled_agent_key = params.dig(:agent_program, :bundled_agent_key).to_s.strip

    if name.blank? || bundled_agent_key.blank?
      flash.now[:alert] = "Name and bundled source are required"
      @bundled_sources = AgentPrograms::BundledSources.available_keys
      render :new, status: :unprocessable_entity
      return
    end

    program = AgentPrograms::Creator.create_from_bundled_source!(name: name, bundled_agent_key: bundled_agent_key)
    redirect_to agent_program_path(program)
  rescue StandardError
    flash.now[:alert] = "Failed to create agent program"
    @bundled_sources = AgentPrograms::BundledSources.available_keys
    render :new, status: :unprocessable_entity
  end

  def show
    @loaded = @agent_program.loaded_program
  end

  private

    def set_agent_program
      @agent_program = AgentProgram.find(params[:id])
    end
end
