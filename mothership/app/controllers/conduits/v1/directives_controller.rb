require "digest"

module Conduits
  module V1
    class DirectivesController < Conduits::V1::ApplicationController
      before_action :authenticate_directive!

      # POST /conduits/v1/directives/:id/started
      #
      # Nexus reports that execution has begun.
      # Transitions directive from leased → running.
      def started
        sandbox_version = params[:sandbox_version].to_s.strip.presence
        nexus_version = params[:nexus_version].to_s.strip.presence

        Conduits::Directive.transaction do
          current_directive.lock!

          if current_directive.running? || terminal_directive?(current_directive)
            if sandbox_version.present? && current_directive.sandbox_version.present? &&
                current_directive.sandbox_version != sandbox_version
              render json: { error: "invalid_state", detail: "sandbox_version mismatch" }, status: :conflict
              return
            end
            if nexus_version.present? && current_directive.nexus_version.present? &&
                current_directive.nexus_version != nexus_version
              render json: { error: "invalid_state", detail: "nexus_version mismatch" }, status: :conflict
              return
            end

            current_directive.sandbox_version ||= sandbox_version
            current_directive.nexus_version ||= nexus_version
            current_directive.save! if current_directive.changed?

            render json: {
              ok: true,
              directive_id: current_directive.id,
              state: current_directive.state,
              duplicate: true,
            }
            return
          end

          unless current_directive.leased?
            render json: { error: "invalid_state", detail: "directive is #{current_directive.state}, expected leased" },
                   status: :conflict
            return
          end

          if sandbox_version.present? && current_directive.sandbox_version.present? &&
              current_directive.sandbox_version != sandbox_version
            render json: { error: "invalid_state", detail: "sandbox_version mismatch" }, status: :conflict
            return
          end
          if nexus_version.present? && current_directive.nexus_version.present? &&
              current_directive.nexus_version != nexus_version
            render json: { error: "invalid_state", detail: "nexus_version mismatch" }, status: :conflict
            return
          end

          current_directive.sandbox_version ||= sandbox_version
          current_directive.nexus_version ||= nexus_version
          current_directive.start!

          time_to_start_ms = ((Time.current - current_directive.created_at) * 1000).round
          audit_for(current_directive).record("directive.started", payload: {
            "time_to_start_ms" => time_to_start_ms,
            "territory_id" => current_directive.territory_id,
            "sandbox_version" => sandbox_version,
          })

          render json: {
            ok: true,
            directive_id: current_directive.id,
            state: current_directive.state,
            duplicate: false,
          }
        end
      rescue AASM::InvalidTransition => e
        render json: { error: "invalid_state", detail: e.message }, status: :conflict
      end

      # POST /conduits/v1/directives/:id/heartbeat
      #
      # Renews lease, refreshes directive JWT, and returns cancel signal if requested.
      # Returns: { cancel_requested, lease_renewed, directive_token }
      def heartbeat
        Conduits::Directive.transaction do
          current_directive.lock!

          unless current_directive.running?
            render json: { error: "invalid_state", detail: "directive is #{current_directive.state}, expected running" },
                   status: :conflict
            return
          end

          current_directive.renew_lease!(
            ttl_seconds: Conduits::PollService::DEFAULT_LEASE_TTL
          )

          refreshed_token = Conduits::DirectiveToken.encode(
            directive_id: current_directive.id,
            territory_id: current_directive.territory_id
          )

          render json: {
            cancel_requested: current_directive.cancel_requested?,
            lease_renewed: true,
            directive_token: refreshed_token,
          }
        end
      end

      # POST /conduits/v1/directives/:id/log_chunks
      #
      # Params: { stream: "stdout"|"stderr", seq: N, bytes: "<base64>", truncated: bool }
      def log_chunks
        unless current_directive.running? || terminal_directive?(current_directive)
          render json: {
                   error: "invalid_state",
                   detail: "directive is #{current_directive.state}, expected running or terminal",
                 },
                 status: :conflict
          return
        end

        stream = params[:stream]
        unless %w[stdout stderr].include?(stream)
          render json: { error: "invalid_param", detail: "stream must be stdout or stderr" },
                 status: :unprocessable_entity
          return
        end

        seq = Integer(params[:seq])
        raise ArgumentError, "seq must be >= 0" if seq < 0

        b64 = params[:bytes].to_s
        decoded_len = base64_decoded_size(b64, field: "bytes")
        max_chunk_bytes = max_log_chunk_bytes
        if decoded_len > max_chunk_bytes
          raise ArgumentError, "bytes too large (max #{max_chunk_bytes} bytes)"
        end

        decoded_bytes = Base64.strict_decode64(b64)
        truncated = cast_bool(params[:truncated])

        ingestor = Conduits::LogChunkIngestor.new(current_directive)
        result = ingestor.ingest!(
          stream: stream,
          seq: seq,
          bytes: decoded_bytes,
          truncated: truncated
        )

        render json: {
          ok: true,
          directive_id: current_directive.id,
          stream: stream,
          seq: seq,
          stored: result.stored,
          duplicate: result.duplicate,
          accepted_bytes: result.accepted_bytes,
          truncated: result.truncated,
        }
      rescue ArgumentError => e
        render json: { error: "invalid_param", detail: e.message }, status: :unprocessable_entity
      end

      # POST /conduits/v1/directives/:id/finished
      #
      # Terminal state report from Nexus.
      # Params: { status, exit_code, stdout_truncated, stderr_truncated, diff_truncated,
      #           snapshot_before, snapshot_after, artifacts_manifest, diff_base64, finished_at }
      def finished
        status = params[:status].to_s.strip
        unless %w[succeeded failed canceled timed_out].include?(status)
          render json: { error: "invalid_param", detail: "status must be succeeded/failed/canceled/timed_out" },
                 status: :unprocessable_entity
          return
        end

        exit_code =
          if params.key?("exit_code")
            value = params[:exit_code]
            value.nil? ? nil : Integer(value)
          end

        diff_data = decode_diff_data(params[:diff_base64], max_bytes: current_directive.max_diff_bytes)
        diff_sha256 = diff_data.present? ? Digest::SHA256.hexdigest(diff_data) : nil

        result_hash = result_hash_for(
          status: status,
          exit_code: exit_code,
          stdout_truncated: cast_bool(params[:stdout_truncated]),
          stderr_truncated: cast_bool(params[:stderr_truncated]),
          diff_truncated: cast_bool(params[:diff_truncated]),
          snapshot_before: params[:snapshot_before],
          snapshot_after: params[:snapshot_after],
          artifacts_manifest: params_to_h(params[:artifacts_manifest], {}),
          diff_sha256: diff_sha256,
          diff_bytesize: diff_data&.bytesize
        )

        Conduits::Directive.transaction do
          current_directive.lock!

          # Idempotency: if already terminal with matching status, acknowledge.
          if terminal_directive?(current_directive)
            if finished_status_matches?(current_directive, status) &&
                result_hash_matches?(current_directive, result_hash)
              current_directive.update!(result_hash: result_hash) if current_directive.result_hash.blank?
              unlock_facility_if_owned!(current_directive)

              render json: {
                ok: true,
                directive_id: current_directive.id,
                final_state: current_directive.state,
                duplicate: true,
              }
              return
            end

            render json: {
              error: "invalid_state",
              detail: "directive is #{current_directive.state} (finished_status=#{current_directive.finished_status.inspect}), " \
                      "cannot apply finished(status=#{status.inspect})",
            }, status: :conflict
            return
          end

          # Allow finished to arrive even if started was lost (leased -> implicit start).
          current_directive.start! if current_directive.leased?

          unless current_directive.running?
            render json: { error: "invalid_state", detail: "directive is #{current_directive.state}, expected running" },
                   status: :conflict
            return
          end

          if current_directive.result_hash.present? && current_directive.result_hash != result_hash
            render json: { error: "invalid_state", detail: "result_hash mismatch" }, status: :conflict
            return
          end

          current_directive.result_hash = result_hash

          # Attach diff blob if provided (best-effort idempotent: only attach once).
          if diff_data.present?
            if current_directive.diff_blob.attached?
              expected_checksum = Digest::MD5.base64digest(diff_data)
              blob = current_directive.diff_blob.blob
              if blob&.checksum != expected_checksum || blob&.byte_size != diff_data.bytesize
                render json: { error: "invalid_state", detail: "diff_blob mismatch" }, status: :conflict
                return
              end
            else
              current_directive.diff_blob.attach(
                io: StringIO.new(diff_data),
                filename: "diff.patch",
                content_type: "text/x-diff"
              )
            end
          end

          # Update directive fields (truncation flags are monotonic: never flip true -> false)
          attrs = {
            finished_status: status,
            stdout_truncated: current_directive.stdout_truncated || cast_bool(params[:stdout_truncated]),
            stderr_truncated: current_directive.stderr_truncated || cast_bool(params[:stderr_truncated]),
            diff_truncated: current_directive.diff_truncated || cast_bool(params[:diff_truncated]),
          }
          attrs[:exit_code] = exit_code if params.key?("exit_code")
          attrs[:snapshot_before] = params[:snapshot_before] if params.key?("snapshot_before")
          attrs[:snapshot_after] = params[:snapshot_after] if params.key?("snapshot_after")
          attrs[:artifacts_manifest] = params_to_h(params[:artifacts_manifest]) if params.key?("artifacts_manifest")
          attrs[:finished_at] = Time.zone.parse(params[:finished_at]) if params[:finished_at].present?
          current_directive.assign_attributes(attrs)

          # Transition state machine
          case status
          when "succeeded" then current_directive.succeed!
          when "failed"    then current_directive.fail!
          when "canceled"  then current_directive.cancel!
          when "timed_out" then current_directive.time_out!
          end

          unlock_facility_if_owned!(current_directive)

          finished_at = current_directive.finished_at || Time.current
          # Total lifecycle time (created → finished). No started_at column exists,
          # so per-phase durations are captured via audit events (see #started).
          total_duration_ms = ((finished_at - current_directive.created_at) * 1000).round
          audit_for(current_directive).record("directive.finished", payload: {
            "status" => status,
            "exit_code" => exit_code,
            "total_duration_ms" => total_duration_ms,
            "territory_id" => current_directive.territory_id,
          })

          render json: {
            ok: true,
            directive_id: current_directive.id,
            final_state: current_directive.state,
            duplicate: false,
          }
        end
      rescue ArgumentError, TypeError => e
        render json: { error: "invalid_param", detail: e.message }, status: :unprocessable_entity
      rescue AASM::InvalidTransition => e
        render json: { error: "invalid_state", detail: e.message }, status: :conflict
      end

      private

      def audit_for(directive)
        Conduits::AuditService.new(account: directive.account, directive: directive)
      end

      def cast_bool(value)
        return value if value == true || value == false

        value.to_s == "true"
      end

      def terminal_directive?(directive)
        directive.succeeded? || directive.failed? || directive.canceled? || directive.timed_out?
      end

      def finished_status_matches?(directive, status)
        return true if directive.finished_status.to_s == status

        # If state was forced to a terminal state without finished_status being set,
        # accept the matching status and treat it as idempotent.
        directive.finished_status.blank? && directive.state.to_s == status
      end

      def unlock_facility_if_owned!(directive)
        return unless directive.facility.locked_by_directive_id == directive.id

        directive.facility.unlock!(directive)
      end

      def decode_diff_data(value, max_bytes:)
        return nil if value.blank?

        b64 = value.to_s
        decoded_len = base64_decoded_size(b64, field: "diff_base64")
        if decoded_len > max_bytes
          raise ArgumentError, "diff_base64 too large (max #{max_bytes} bytes)"
        end

        Base64.strict_decode64(b64)
      end

      def base64_decoded_size(b64, field:)
        len = b64.bytesize
        raise ArgumentError, "#{field} must be base64" if (len % 4) != 0

        padding =
          if b64.end_with?("==")
            2
          elsif b64.end_with?("=")
            1
          else
            0
          end

        (len / 4) * 3 - padding
      end

      def max_log_chunk_bytes
        default = 256.kilobytes
        max = ENV.fetch("CONDUITS_LOG_CHUNK_MAX_BYTES", default).to_i
        max.positive? ? max : default
      end

      def result_hash_for(
        status:,
        exit_code:,
        stdout_truncated:,
        stderr_truncated:,
        diff_truncated:,
        snapshot_before:,
        snapshot_after:,
        artifacts_manifest:,
        diff_sha256:,
        diff_bytesize:
      )
        report = {
          "status" => status,
          "exit_code" => exit_code,
          "stdout_truncated" => stdout_truncated ? true : false,
          "stderr_truncated" => stderr_truncated ? true : false,
          "diff_truncated" => diff_truncated ? true : false,
          "snapshot_before" => snapshot_before,
          "snapshot_after" => snapshot_after,
          "artifacts_manifest" => normalize_json(artifacts_manifest || {}),
          "diff" => diff_sha256.present? ? { "sha256" => diff_sha256, "bytesize" => diff_bytesize } : nil,
        }

        Digest::SHA256.hexdigest(JSON.generate(normalize_json(report)))
      end

      def normalize_json(value)
        case value
        when Hash
          value
            .map { |k, v| [k.to_s, normalize_json(v)] }
            .sort_by(&:first)
            .to_h
        when Array
          value.map { |v| normalize_json(v) }
        else
          value
        end
      end

      def result_hash_matches?(directive, result_hash)
        existing = directive.result_hash.to_s
        return true if existing.blank?

        candidate = result_hash.to_s
        return false unless existing.bytesize == candidate.bytesize

        ActiveSupport::SecurityUtils.secure_compare(existing, candidate)
      end
    end
  end
end
