module Conduits
  module V1
    class CommandsController < Conduits::V1::ApplicationController
      # GET /conduits/v1/commands/pending
      #
      # Territory polls for pending commands (REST fallback when WebSocket unavailable).
      # Returns queued commands for this territory, marking them as dispatched.
      def pending
        max = (params[:max] || 5).to_i.clamp(1, 20)

        dispatched = []

        Conduits::Command.transaction do
          Conduits::Command
            .where(territory_id: current_territory.id, state: "queued")
            .order(created_at: :asc)
            .limit(max)
            .lock("FOR UPDATE SKIP LOCKED")
            .each do |cmd|
              cmd.dispatch!
              dispatched << {
                command_id: cmd.id,
                capability: cmd.capability,
                params: cmd.params,
                bridge_entity_ref: cmd.bridge_entity&.entity_ref,
                timeout_seconds: cmd.timeout_seconds,
                created_at: cmd.created_at.iso8601,
              }
            rescue AASM::InvalidTransition
              next
            end
        end

        render json: {
          commands: dispatched,
          retry_after_seconds: dispatched.empty? ? 5 : 2,
        }
      end

      # POST /conduits/v1/commands/:id/result
      #
      # Territory submits command execution result.
      # Supports result_hash for idempotency (matching Directive track pattern).
      def result
        command = current_territory.commands.find_by(id: params[:id])

        unless command
          render json: { error: "not_found", detail: "command not found" }, status: :not_found
          return
        end

        status_param = params[:status].to_s
        result_data = params_to_h(params[:result])
        error_msg = params[:error_message]
        incoming_hash = command.compute_result_hash(
          status: status_param, result_data: result_data, error_message: error_msg
        )

        # Idempotency: if already terminal, check consistency
        if command.terminal?
          if command.result_hash.present? && command.result_hash != incoming_hash
            render json: {
              error: "invalid_state",
              detail: "result_hash mismatch (command already #{command.state})",
            }, status: :conflict
            return
          end

          render json: { ok: true, command_id: command.id, final_state: command.state, duplicate: true }
          return
        end

        ActiveRecord::Base.transaction do
          command.update!(
            result: result_data,
            error_message: error_msg,
            result_hash: incoming_hash
          )

          if params[:attachment_base64].present?
            begin
              raw_b64 = params[:attachment_base64]
              max_b64_size = (Conduits::Command::MAX_ATTACHMENT_BYTES * 4 / 3) + 4
              if raw_b64.bytesize > max_b64_size
                render json: { error: "invalid_param", detail: "attachment exceeds size limit" }, status: :unprocessable_entity
                raise ActiveRecord::Rollback
              end

              decoded = Base64.strict_decode64(raw_b64)
              command.result_attachment.attach(
                io: StringIO.new(decoded),
                filename: params[:attachment_filename] || "result",
                content_type: params[:attachment_content_type] || "application/octet-stream"
              )
            rescue ArgumentError
              render json: { error: "invalid_param", detail: "invalid attachment_base64" }, status: :unprocessable_entity
              raise ActiveRecord::Rollback
            end
          end

          case status_param
          when "completed"
            command.complete!
          when "failed"
            command.fail!
          else
            render json: { error: "invalid_param", detail: "status must be 'completed' or 'failed'" },
                   status: :unprocessable_entity
            raise ActiveRecord::Rollback
          end
        end

        return if performed?

        Conduits::AuditService.new(account: command.account, command: command).record(
          "command.#{command.state}",
          payload: {
            command_id: command.id,
            capability: command.capability,
            territory_id: command.territory_id,
            via: "rest",
          }
        )

        render json: { ok: true, command_id: command.id, final_state: command.state }
      end

      # POST /conduits/v1/commands/:id/cancel
      #
      # Cancel a queued or dispatched command.
      def cancel
        command = current_territory.commands.find_by(id: params[:id])

        unless command
          render json: { error: "not_found", detail: "command not found" }, status: :not_found
          return
        end

        if command.terminal?
          render json: { ok: true, command_id: command.id, final_state: command.state, already_terminal: true }
          return
        end

        # Territory cannot cancel commands awaiting human approval
        if command.awaiting_approval?
          render json: { error: "forbidden", detail: "cannot cancel a command awaiting approval" }, status: :forbidden
          return
        end

        command.cancel!

        Conduits::AuditService.new(account: command.account, command: command).record(
          "command.canceled",
          payload: { command_id: command.id, capability: command.capability }
        )

        render json: { ok: true, command_id: command.id, final_state: "canceled" }
      end
    end
  end
end
