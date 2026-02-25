module Mothership
  class DirectivesController < ApplicationController
    def index
      scope = Conduits::Directive.includes(:facility, :territory).order(created_at: :desc)
      scope = scope.where(account_id: params[:account_id]) if params[:account_id].present?

      limit = int_param(:limit, default: 200)
      limit = 200 if limit.nil? || limit <= 0
      limit = [limit, 500].min

      @directives = scope.limit(limit)
    end

    def show
      @directive = Conduits::Directive.includes(:facility, :territory).find(params[:id])
    end

    # GET /mothership/directives/:id/log?stream=stdout|stderr&after_seq=&limit=
    def log
      directive = Conduits::Directive.find(params[:id])

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
        stream: stream,
        after_seq: after_seq,
        limit: limit,
        chunks: chunk_payloads,
        next_after_seq: next_after_seq,
        stdout_truncated: directive.stdout_truncated,
        stderr_truncated: directive.stderr_truncated,
      }
    end

    # GET /mothership/directives/:id/diff
    def diff
      directive = Conduits::Directive.find(params[:id])
      unless directive.diff_blob.attached?
        render plain: "diff not found", status: :not_found
        return
      end

      redirect_to rails_blob_path(directive.diff_blob, disposition: "attachment")
    end

    private

    def int_param(name, default:)
      value = params[name]
      return default if value.nil?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
