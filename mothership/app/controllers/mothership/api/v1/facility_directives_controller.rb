module Mothership
  module API
    module V1
      class FacilityDirectivesController < BaseController
        before_action :set_facility

        # POST /mothership/api/v1/facilities/:facility_id/directives
        #
        # Create a new directive for execution.
        # Params: { command, shell, cwd, sandbox_profile, timeout_seconds,
        #           requested_capabilities, env_allowlist, env_refs, limits }
        def create
          sandbox_profile = params[:sandbox_profile] || "untrusted"
          requested_capabilities = params_to_h(params[:requested_capabilities])

          directive = @facility.directives.build(
            account: @facility.account,
            command: params.require(:command),
            shell: params[:shell],
            cwd: params[:cwd],
            sandbox_profile: sandbox_profile,
            timeout_seconds: params[:timeout_seconds] || 300,
            requested_capabilities: requested_capabilities,
            env_allowlist: params_to_h(params[:env_allowlist], []),
            env_refs: params_to_h(params[:env_refs], []),
            limits: params_to_h(params[:limits]),
            requested_by_user: current_user
          )

          # Phase 2c: Command validation (before policy evaluation)
          cmd_result = Conduits::CommandValidator.validate(
            directive.command, sandbox_profile: sandbox_profile
          )

          if cmd_result.verdict == :forbidden
            audit = Conduits::AuditService.new(
              account: @facility.account, actor: current_user
            )
            audit.record("directive.command_forbidden", severity: "critical", payload: {
              "command" => directive.command,
              "sandbox_profile" => sandbox_profile,
              "violations" => cmd_result.violations,
            })

            render json: {
              error: "command_forbidden",
              violations: cmd_result.violations,
            }, status: :unprocessable_entity
            return
          end

          evaluation = Conduits::PolicyResolver.new(directive).call

          # Combine command validation verdict with policy verdict (most restrictive wins)
          combined_verdict = combine_verdicts(evaluation.approval_verdict, cmd_result.verdict)
          combined_reasons = evaluation.approval_reasons + cmd_result.violations

          audit = Conduits::AuditService.new(
            account: @facility.account, actor: current_user
          )

          case combined_verdict
          when :forbidden
            audit.record("directive.policy_forbidden", severity: "critical", payload: {
              "command" => directive.command,
              "sandbox_profile" => directive.sandbox_profile,
              "reasons" => combined_reasons,
              "policies_applied" => evaluation.policies_applied,
            })

            render json: {
              error: "policy_forbidden",
              reasons: combined_reasons,
            }, status: :forbidden
            return
          when :needs_approval
            directive.effective_capabilities = evaluation.effective_capabilities
            directive.policy_snapshot = evaluation.policy_snapshot
            directive.state = "awaiting_approval"

            if directive.save
              audit_for(directive).record("directive.created", payload: {
                "verdict" => "needs_approval",
                "reasons" => combined_reasons,
                "policies_applied" => evaluation.policies_applied,
              })

              render json: {
                directive_id: directive.id,
                state: directive.state,
                approval_reasons: combined_reasons,
                created_at: directive.created_at,
              }, status: :accepted
            else
              render json: { error: "validation_failed", details: directive.errors.full_messages },
                     status: :unprocessable_entity
            end
            return
          end

          # :skip — normal flow
          directive.effective_capabilities = evaluation.effective_capabilities
          directive.policy_snapshot = evaluation.policy_snapshot

          if directive.save
            audit_for(directive).record("directive.created", payload: {
              "verdict" => "skip",
              "policies_applied" => evaluation.policies_applied,
            })

            # Wake up WebSocket-connected territories
            Conduits::DirectiveNotifier.new.notify(directive)

            render json: {
              directive_id: directive.id,
              state: directive.state,
              created_at: directive.created_at,
            }, status: :created
          else
            render json: { error: "validation_failed", details: directive.errors.full_messages },
                   status: :unprocessable_entity
          end
        end

        # POST /mothership/api/v1/facilities/:facility_id/directives/:id/approve
        def approve
          directive = @facility.directives.find(params[:id])

          if directive.requested_by_user_id == current_user.id
            render json: {
              error: "forbidden",
              detail: "cannot approve own directive",
            }, status: :forbidden
            return
          end

          unless directive.awaiting_approval?
            render json: {
              error: "state_conflict",
              detail: "directive is #{directive.state}, not awaiting_approval",
            }, status: :conflict
            return
          end

          directive.approved_by_user = current_user
          directive.approve!

          audit_for(directive).record("directive.approved", payload: {
            "approved_by_user_id" => current_user.id,
          })

          # Wake up WebSocket-connected territories
          Conduits::DirectiveNotifier.new.notify(directive)

          render json: {
            directive_id: directive.id,
            state: directive.state,
            approved_by_user_id: current_user.id,
          }
        end

        # POST /mothership/api/v1/facilities/:facility_id/directives/:id/reject
        def reject
          directive = @facility.directives.find(params[:id])

          unless directive.awaiting_approval?
            render json: {
              error: "state_conflict",
              detail: "directive is #{directive.state}, not awaiting_approval",
            }, status: :conflict
            return
          end

          directive.reject!

          audit_for(directive).record("directive.rejected", payload: {
            "rejected_by_user_id" => current_user.id,
          })

          render json: {
            directive_id: directive.id,
            state: directive.state,
          }
        end

        # GET /mothership/api/v1/facilities/:facility_id/directives/:id
        def show
          directive = @facility.directives.find(params[:id])

          render json: directive_json(directive)
        end

        # GET /mothership/api/v1/facilities/:facility_id/directives/:id/log_chunks
        #
        # Query log chunks by stream and sequence for UI/debugging.
        # Params:
        #   - stream: stdout|stderr (required)
        #   - after_seq: integer (default -1; returns seq > after_seq)
        #   - limit: integer (default 200; max 500)
        def log_chunks
          directive = @facility.directives.find(params[:id])

          stream = params[:stream].to_s
          unless %w[stdout stderr].include?(stream)
            render json: { error: "invalid_stream" }, status: :unprocessable_entity
            return
          end

          after_seq = int_param(:after_seq, default: -1)
          if after_seq.nil? || after_seq < -1
            render json: { error: "invalid_after_seq" }, status: :unprocessable_entity
            return
          end

          limit = int_param(:limit, default: 200)
          if limit.nil? || limit <= 0
            render json: { error: "invalid_limit" }, status: :unprocessable_entity
            return
          end

          limit = [limit, 500].min

          chunks = directive
            .log_chunks
            .where(stream: stream)
            .where("seq > ?", after_seq)
            .order(:seq)
            .limit(limit)

          chunk_payloads = chunks.map do |chunk|
            {
              seq: chunk.seq,
              bytes_base64: Base64.strict_encode64(chunk.bytes),
              bytesize: chunk.bytesize,
              truncated: chunk.truncated,
              created_at: chunk.created_at&.iso8601,
            }
          end

          next_after_seq = chunk_payloads.last ? chunk_payloads.last[:seq] : after_seq

          render json: {
            directive_id: directive.id,
            facility_id: @facility.id,
            stream: stream,
            after_seq: after_seq,
            limit: limit,
            chunks: chunk_payloads,
            next_after_seq: next_after_seq,
            stdout_truncated: directive.stdout_truncated,
            stderr_truncated: directive.stderr_truncated,
          }
        end

        # GET /mothership/api/v1/facilities/:facility_id/directives
        def index
          directives = @facility.directives.order(created_at: :desc).limit(50)

          render json: { directives: directives.map { |d| directive_json(d) } }
        end

        private

        def set_facility
          # Scope facility lookup to the authenticated account
          @facility = Conduits::Facility.where(account: @current_account).find(params[:facility_id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "not_found", detail: "facility not found" }, status: :not_found
        end

        def audit_for(directive)
          Conduits::AuditService.new(
            account: @facility.account,
            directive: directive,
            actor: current_user
          )
        end

        def directive_json(directive)
          {
            id: directive.id,
            state: directive.state,
            command: directive.command,
            shell: directive.shell,
            sandbox_profile: directive.sandbox_profile,
            exit_code: directive.exit_code,
            finished_status: directive.finished_status,
            territory_id: directive.territory_id,
            created_at: directive.created_at,
            updated_at: directive.updated_at,
          }
        end

        # Combine two verdicts — most restrictive wins.
        # forbidden > needs_approval > skip/safe
        VERDICT_RANK = { skip: 0, safe: 0, needs_approval: 1, forbidden: 2 }.freeze

        def combine_verdicts(policy_verdict, command_verdict)
          rank_a = VERDICT_RANK.fetch(policy_verdict, 0)
          rank_b = VERDICT_RANK.fetch(command_verdict, 0)
          worst_rank = [rank_a, rank_b].max
          VERDICT_RANK.key(worst_rank) || :skip
        end

        def int_param(name, default:)
          value = params[name]
          return default if value.nil?

          Integer(value)
        rescue ArgumentError, TypeError
          nil
        end
      end
    end
  end
end
