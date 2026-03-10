module System
  module Settings
    class AgentDeploymentsController < BaseController
      helper_method :agent_program_source_kind_label,
        :agent_program_lineage_label,
        :agent_program_lineage_value,
        :agent_program_source_root,
        :deployment_launch_owner_label,
        :deployment_launch_status_label,
        :deployment_active_timestamp

      before_action :set_agent_deployment, only: %i[show inspect activate]
      before_action :load_agent_programs, only: %i[index new create]

      def index
        @agent_deployments = AgentDeployment.includes(agent_program: :forked_from_agent_program).order(created_at: :desc)
      end

      def new
        @agent_deployment = AgentDeployment.new(transport_kind: "http_jsonrpc")
      end

      def create
        agent_program = AgentProgram.find_by(id: params.dig(:agent_deployment, :agent_program_id))
        @agent_deployment =
          AgentDeployment.new(
            agent_program: agent_program,
            transport_kind: params.dig(:agent_deployment, :transport_kind).to_s,
            endpoint_url: params.dig(:agent_deployment, :endpoint_url).to_s,
            deployment_bearer_secret_ref: params.dig(:agent_deployment, :deployment_bearer_secret_ref).to_s,
            deployment_fingerprint: params.dig(:agent_deployment, :deployment_fingerprint).to_s,
          )

        if agent_program.nil?
          @agent_deployment.errors.add(:agent_program, "must exist")
          render :new, status: :unprocessable_entity
          return
        end

        deployment =
          AgentDeployments::RegistrationService.new(
            agent_program: agent_program,
            transport_kind: @agent_deployment.transport_kind,
            endpoint_url: @agent_deployment.endpoint_url,
            deployment_bearer_secret_ref: @agent_deployment.deployment_bearer_secret_ref,
            deployment_fingerprint: @agent_deployment.deployment_fingerprint,
          ).register!

        flash[:notice] = "Deployment registered"
        redirect_to system_settings_agent_deployment_path(deployment)
      rescue ActiveRecord::RecordInvalid => e
        @agent_deployment = e.record
        render :new, status: :unprocessable_entity
      end

      def show
      end

      def inspect
        AgentDeployments::InspectionService.new(deployment: @agent_deployment).inspect!
        flash[:notice] = "Deployment inspected"
        redirect_to system_settings_agent_deployment_path(@agent_deployment)
      rescue AgentDeployments::Error => e
        flash.now[:alert] = e.message
        render :show, status: :unprocessable_entity
      end

      def activate
        AgentDeployments::ActivationService.new(deployment: @agent_deployment).activate!
        flash[:notice] = "Deployment activated"
        redirect_to system_settings_agent_deployment_path(@agent_deployment)
      rescue AgentDeployments::ActivationError => e
        flash.now[:alert] = e.message
        render :show, status: :unprocessable_entity
      end

      private

        def set_agent_deployment
          @agent_deployment = AgentDeployment.includes(agent_program: :forked_from_agent_program).find(params[:id])
        end

        def load_agent_programs
          @agent_programs = AgentProgram.order(created_at: :asc)
        end

        def agent_program_source_kind_label(program)
          program.bundled_source? ? "Bundled" : "Custom"
        end

        def agent_program_lineage_label(program)
          program.bundled_source? ? "Bundled key" : "Fork origin"
        end

        def agent_program_lineage_value(program)
          return program.bundled_agent_key if program.bundled_source?
          return program.forked_from_agent_program.name if program.forked_from_agent_program.present?

          "Standalone custom source"
        end

        def agent_program_source_root(program)
          program.absolute_local_path.to_s
        rescue StandardError
          program.local_path.to_s.presence || "n/a"
        end

        def deployment_launch_owner_label(deployment)
          deployment.managed_local_http_jsonrpc? ? "Cybros managed local supervisor" : "Operator-managed external deployment"
        end

        def deployment_launch_status_label(deployment)
          if deployment.managed_local_http_jsonrpc?
            return "Launched" if deployment.active? && deployment.health_status == "healthy"
            return "Launch failed" if deployment.inspection_details.dig("supervisor", "failed_at").present?

            "Launch pending"
          elsif deployment.active? && deployment.health_status == "healthy"
            "Externally launched"
          else
            "Registered endpoint"
          end
        end

        def deployment_active_timestamp(deployment)
          deployment.activated_at&.iso8601 || "n/a"
        end
    end
  end
end
