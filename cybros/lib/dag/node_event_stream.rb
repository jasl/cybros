module DAG
  class NodeEventStream
    DEFAULT_FLUSH_INTERVAL = 0.25
    DEFAULT_FLUSH_BYTES = 1024

    def initialize(node:, flush_interval: DEFAULT_FLUSH_INTERVAL, flush_bytes: DEFAULT_FLUSH_BYTES)
      @node = node
      @graph_id = node.graph_id
      @node_id = node.id
      @body_id = node.body_id

      @flush_interval = Float(flush_interval)
      @flush_bytes = Integer(flush_bytes)

      @output_preview_key = output_preview_key_for(node)
      @output_preview = fetch_output_preview_for(node)

      @buffer = +""
      @last_flush_at = Time.current
    end

    def output_delta(delta)
      append_output_delta(delta, flush: false)
    end

    def output_delta!(delta)
      append_output_delta(delta, flush: true)
    end

    def progress(phase:, message:, percent: nil, data: {})
      emit(
        kind: DAG::NodeEvent::PROGRESS,
        payload: {
          "phase" => phase.to_s,
          "message" => message.to_s,
          "percent" => percent,
          "data" => normalize_payload_hash(data),
        }.compact
      )
    end

    def log(line, level: "info")
      emit(
        kind: DAG::NodeEvent::LOG,
        text: line.to_s,
        payload: { "level" => level.to_s }
      )
    end

    def flush!
      flush_buffer_if_needed(force: true)
    end

    private

      def append_output_delta(delta, flush:)
        delta = delta.to_s
        return if delta.empty?

        @buffer << delta
        flush_buffer_if_needed(force: flush)
      end

      def flush_buffer_if_needed(force:)
        return if @buffer.empty?

        if force || should_flush?
          flush_buffer!
        end
      end

      def should_flush?
        @buffer.bytesize >= @flush_bytes ||
          (Time.current - @last_flush_at) >= @flush_interval
      end

      def flush_buffer!
        chunk = @buffer
        @buffer = +""

        emit(kind: DAG::NodeEvent::OUTPUT_DELTA, text: chunk, payload: {})
        apply_output_preview_patch(chunk)

        @last_flush_at = Time.current
      end

      def apply_output_preview_patch(chunk)
        return if @output_preview_key.blank?

        preview_max_chars = @node.body.preview_max_chars
        current = @output_preview.fetch(@output_preview_key, "").to_s.dup
        current << chunk
        current = current.truncate(preview_max_chars)

        @output_preview[@output_preview_key] = current

        DAG::NodeBody.where(id: @body_id).update_all(
          output_preview: @output_preview,
          updated_at: Time.current
        )
      end

      def emit(kind:, text: nil, payload: {})
        payload = normalize_payload_hash(payload)

        DAG::NodeEvent.create!(
          graph_id: @graph_id,
          node_id: @node_id,
          kind: kind.to_s,
          text: text,
          payload: payload
        )
      end

      def output_preview_key_for(node)
        destination = node.body.class.created_content_destination
        if destination.is_a?(Array) &&
             destination.length == 2 &&
             destination.first == :output &&
             destination.last.is_a?(String) &&
             destination.last.present?
          destination.last
        else
          nil
        end
      end

      def fetch_output_preview_for(node)
        output_preview = node.body.output_preview
        if output_preview.is_a?(Hash)
          output_preview.deep_stringify_keys
        else
          {}
        end
      end

      def normalize_payload_hash(payload)
        if payload.is_a?(Hash)
          payload.deep_stringify_keys
        else
          {}
        end
      end
  end
end
