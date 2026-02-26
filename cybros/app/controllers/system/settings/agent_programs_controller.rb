module System
  module Settings
    class AgentProgramsController < BaseController
      before_action :set_agent_program, only: %i[show]

      def index
        @q = params[:q].to_s.strip
        scope = AgentProgram.order(created_at: :asc)

        if @q.present?
          q = "%#{ActiveRecord::Base.sanitize_sql_like(@q)}%"
          scope = scope.where("name ILIKE ? OR profile_source ILIKE ?", q, q)
        end

        @agent_programs = scope
      end

      def new
        @profiles = AgentPrograms::BundledProfiles.available
      end

      def create
        name = params.dig(:agent_program, :name).to_s.strip
        profile_source = params.dig(:agent_program, :profile_source).to_s.strip

        if name.blank? || profile_source.blank?
          flash.now[:alert] = "Name and profile are required"
          @profiles = AgentPrograms::BundledProfiles.available
          render :new, status: :unprocessable_entity
          return
        end

        program = AgentPrograms::Creator.create_from_profile!(name: name, profile_source: profile_source)
        redirect_to system_settings_agent_program_path(program)
      rescue StandardError
        flash.now[:alert] = "Failed to create agent program"
        @profiles = AgentPrograms::BundledProfiles.available
        render :new, status: :unprocessable_entity
      end

      def show
        base = @agent_program.local_path.to_s
        @base_dir = Rails.root.join(base)
        @loaded = AgentPrograms::Loader.new(base_dir: @base_dir).load
      end

      private

        def set_agent_program
          @agent_program = AgentProgram.find(params[:id])
        end
    end
  end
end
