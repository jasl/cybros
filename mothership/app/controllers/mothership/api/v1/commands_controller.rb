module Mothership
  module API
    module V1
      class CommandsController < BaseController
        before_action :set_command, only: %i[show approve reject]

        # POST /mothership/api/v1/commands
        #
        # Create a command with device policy evaluation.
        # Params: { capability, params, target, timeout_seconds }
        #
        # target: { territory_id?, location?, tag?, entity_ref? }
        def create
          capability = params.require(:capability)
          command_params = params_to_h(params[:params])
          target = params_to_h(params[:target])
          timeout_seconds = (params[:timeout_seconds] || 30).to_i.clamp(1, 300)

          # Resolve target territory (and optional bridge entity)
          resolver = Conduits::CommandTargetResolver.new
          resolution = resolver.resolve(
            account: @current_account,
            capability: capability,
            target: target
          )

          # Evaluate device policy
          gate = Conduits::CommandPolicyGate.new(
            account: @current_account,
            capability: capability,
            user: current_user
          )
          policy_result = gate.call

          if policy_result.verdict == :denied
            audit.record("command.policy_denied", severity: "warn", payload: {
              "capability" => capability,
              "reason" => policy_result.reason,
              "policies_applied" => policy_result.policies_applied,
            })

            render json: {
              error: "policy_denied",
              reason: policy_result.reason,
              policies_applied: policy_result.policies_applied,
            }, status: :forbidden
            return
          end

          command = Conduits::Command.new(
            account: @current_account,
            territory: resolution.territory,
            bridge_entity: resolution.entity,
            requested_by_user: current_user,
            capability: capability,
            params: command_params,
            timeout_seconds: timeout_seconds,
            policy_snapshot: policy_result.policy_snapshot,
          )

          if policy_result.verdict == :needs_approval
            command.approval_reasons = [policy_result.reason]

            unless command.save
              render json: { error: "validation_failed", details: command.errors.full_messages },
                     status: :unprocessable_entity
              return
            end

            # Transition via AASM event (not direct state assignment)
            command.request_approval!

            audit_for(command).record("command.awaiting_approval", payload: {
              "capability" => capability,
              "reason" => policy_result.reason,
              "policies_applied" => policy_result.policies_applied,
            })

            render json: {
              command_id: command.id,
              state: command.state,
              approval_reasons: command.approval_reasons,
              created_at: command.created_at,
            }, status: :accepted
            return
          end

          # :allowed — normal flow
          unless command.save
            render json: { error: "validation_failed", details: command.errors.full_messages },
                   status: :unprocessable_entity
            return
          end

          audit_for(command).record("command.created", payload: {
            "capability" => capability,
            "territory_id" => resolution.territory.id,
            "bridge_entity_id" => resolution.entity&.id,
            "verdict" => "allowed",
          })

          # Dispatch immediately
          dispatch_method = Conduits::CommandDispatcher.new.dispatch(command)

          render json: {
            command_id: command.id,
            state: command.state,
            dispatched_via: dispatch_method,
            created_at: command.created_at,
          }, status: :created

        rescue Conduits::NoTargetAvailable => e
          render json: { error: "no_target", detail: e.message }, status: :not_found
        end

        # POST /mothership/api/v1/commands/:id/approve
        def approve
          if @command.requested_by_user_id == current_user.id
            render json: { error: "forbidden", detail: "cannot approve own command" }, status: :forbidden
            return
          end

          ActiveRecord::Base.transaction do
            @command.lock!

            unless @command.awaiting_approval?
              render json: {
                error: "state_conflict",
                detail: "command is #{@command.state}, not awaiting_approval",
              }, status: :conflict
              raise ActiveRecord::Rollback
            end

            @command.update!(approved_by_user: current_user)
            @command.approve!
          end

          return if performed?

          audit_for(@command).record("command.approved", payload: {
            "approved_by_user_id" => current_user.id,
          })

          # Dispatch now that it's approved (outside transaction — side-effect)
          dispatch_method = Conduits::CommandDispatcher.new.dispatch(@command)

          render json: {
            command_id: @command.id,
            state: @command.state,
            dispatched_via: dispatch_method,
          }
        rescue AASM::InvalidTransition
          render json: { error: "state_conflict", detail: "command state changed concurrently" },
                 status: :conflict
        end

        # POST /mothership/api/v1/commands/:id/reject
        def reject
          ActiveRecord::Base.transaction do
            @command.lock!

            unless @command.awaiting_approval?
              render json: {
                error: "state_conflict",
                detail: "command is #{@command.state}, not awaiting_approval",
              }, status: :conflict
              raise ActiveRecord::Rollback
            end

            @command.reject!
          end

          return if performed?

          audit_for(@command).record("command.rejected", payload: {
            "rejected_by_user_id" => current_user.id,
          })

          render json: {
            command_id: @command.id,
            state: @command.state,
          }
        rescue AASM::InvalidTransition
          render json: { error: "state_conflict", detail: "command state changed concurrently" },
                 status: :conflict
        end

        # GET /mothership/api/v1/commands/:id
        def show
          render json: command_json(@command)
        end

        # GET /mothership/api/v1/commands
        def index
          commands = Conduits::Command
            .where(account_id: @current_account.id)
            .order(created_at: :desc)
            .limit(50)

          render json: { commands: commands.map { |c| command_json(c) } }
        end

        private

        def set_command
          @command = Conduits::Command.where(account_id: @current_account.id).find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "not_found", detail: "command not found" }, status: :not_found
        end

        def audit
          Conduits::AuditService.new(account: @current_account, actor: current_user)
        end

        def audit_for(command)
          Conduits::AuditService.new(account: @current_account, command: command, actor: current_user)
        end

        def command_json(command)
          {
            id: command.id,
            state: command.state,
            capability: command.capability,
            params: command.params,
            territory_id: command.territory_id,
            bridge_entity_id: command.bridge_entity_id,
            approval_reasons: command.approval_reasons,
            created_at: command.created_at,
            dispatched_at: command.dispatched_at,
            completed_at: command.completed_at,
            result: command.result,
            error_message: command.error_message,
          }
        end
      end
    end
  end
end
