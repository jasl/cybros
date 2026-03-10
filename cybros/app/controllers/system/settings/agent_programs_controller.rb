module System
  module Settings
    class AgentProgramsController < BaseController
      before_action :set_agent_program, only: %i[show fork]

      def index
        @q = params[:q].to_s.strip
        scope = AgentProgram.order(created_at: :asc)

        if @q.present?
          q = "%#{ActiveRecord::Base.sanitize_sql_like(@q)}%"
          scope = scope.where("name ILIKE ? OR bundled_agent_key ILIKE ? OR source_kind ILIKE ?", q, q, q)
        end

        @agent_programs = scope
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
        redirect_to system_settings_agent_program_path(program)
      rescue StandardError
        flash.now[:alert] = "Failed to create agent program"
        @bundled_sources = AgentPrograms::BundledSources.available_keys
        render :new, status: :unprocessable_entity
      end

      def show
        @loaded = @agent_program.loaded_program
      end

      def fork
        fork_name = params[:name].to_s.strip.presence || params.dig(:agent_program, :name).to_s.strip.presence
        program = AgentPrograms::ForkService.call!(source_program: @agent_program, name: fork_name)
        redirect_to system_settings_agent_program_path(program)
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        @loaded = @agent_program.loaded_program
        flash.now[:alert] = e.message
        render :show, status: :unprocessable_entity
      end

      private

        def set_agent_program
          @agent_program = AgentProgram.find(params[:id])
        end
    end
  end
end
