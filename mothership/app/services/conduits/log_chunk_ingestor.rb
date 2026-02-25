module Conduits
  class LogChunkIngestor
    Result = Data.define(:stored, :duplicate, :accepted_bytes, :truncated)

    def initialize(directive)
      @directive = directive
    end

    def ingest!(stream:, seq:, bytes:, truncated:)
      bytes = bytes.to_s.b

      Directive.transaction do
        @directive.lock!

        if LogChunk.exists?(directive_id: @directive.id, stream: stream, seq: seq)
          mark_stream_truncated!(stream) if truncated
          return Result.new(stored: false, duplicate: true, accepted_bytes: 0, truncated: truncated)
        end

        accepted = accept_bytes_for_directive(stream, bytes)
        partial = accepted.bytesize < bytes.bytesize
        chunk_truncated = truncated || partial

        if accepted.empty?
          mark_stream_truncated!(stream)
          return Result.new(stored: false, duplicate: false, accepted_bytes: 0, truncated: true)
        end

        LogChunk.create!(
          directive: @directive,
          stream: stream,
          seq: seq,
          bytes: accepted,
          bytesize: accepted.bytesize,
          truncated: chunk_truncated
        )

        bump_stream_bytes!(stream, accepted.bytesize)
        mark_stream_truncated!(stream) if chunk_truncated

        Result.new(stored: true, duplicate: false, accepted_bytes: accepted.bytesize, truncated: chunk_truncated)
      end
    rescue ActiveRecord::RecordNotUnique
      mark_stream_truncated!(stream) if truncated
      Result.new(stored: false, duplicate: true, accepted_bytes: 0, truncated: truncated)
    end

    private

    def accept_bytes_for_directive(stream, bytes)
      remaining = @directive.max_output_bytes - (@directive.stdout_bytes.to_i + @directive.stderr_bytes.to_i)
      if remaining <= 0
        return "".b
      end

      bytes.byteslice(0, remaining)
    end

    def bump_stream_bytes!(stream, delta)
      return if delta <= 0

      # Use SQL atomic increment to avoid lost updates under concurrent ingestion.
      column = case stream
      when "stdout" then :stdout_bytes
      when "stderr" then :stderr_bytes
      else return
      end

      Directive.where(id: @directive.id).update_all(["#{column} = #{column} + ?", delta])
      @directive.reload
    end

    def mark_stream_truncated!(stream)
      case stream
      when "stdout"
        @directive.update!(stdout_truncated: true)
      when "stderr"
        @directive.update!(stderr_truncated: true)
      end
    end
  end
end
