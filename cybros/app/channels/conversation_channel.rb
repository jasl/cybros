class ConversationChannel < ApplicationCable::Channel
  include ActionCable::Channel::PeriodicTimers

  periodically :poll_fallback, every: 10

  def subscribed
    identity_id = connection.respond_to?(:current_identity_id) ? connection.current_identity_id : nil
    if identity_id.blank?
      reject
      return
    end

    conversation_id = params[:conversation_id].to_s.presence
    if conversation_id.blank? || !AgentCore::Utils.uuid_like?(conversation_id)
      reject
      return
    end

    @conversation = Conversation.find_by(id: conversation_id)
    if @conversation.nil?
      reject
      return
    end

    user = Identity.find_by(id: identity_id)&.user
    if user.nil? || @conversation.user_id != user.id
      reject
      return
    end

    stream_for @conversation

    @node_id = params[:node_id].to_s.presence
    @node_id = nil unless @node_id.present? && AgentCore::Utils.uuid_like?(@node_id)

    @cursor = params[:cursor].to_s.presence
    @cursor = nil unless @cursor.present? && AgentCore::Utils.uuid_like?(@cursor)

    if @node_id.blank?
      @node_id = @conversation.chat_head_node_id
    end

    if @cursor.blank? && @node_id.present?
      @cursor = @conversation.cursor_for_existing_output(@node_id)
    end

    provided_node_id = params[:node_id].to_s.presence
    provided_cursor = params[:cursor].to_s.presence

    Rails.logger.info(
      {
        msg: "conversation_channel_subscribed",
        event: "subscribed",
        source: "subscribe",
        conversation_id: @conversation.id.to_s,
        node_id: @node_id.to_s,
        cursor: @cursor.to_s,
        provided_node_id: provided_node_id.to_s,
        provided_cursor: provided_cursor.to_s,
      }.to_json
    )

    replay_missed_events!(source: "subscribe")
  end

  def poll_fallback
    replay_missed_events!(source: "poll_fallback")
  rescue StandardError => e
    rate_limited_warn(e)
    nil
  end

  class << self
    def broadcast_node_event(conversation, node_event)
      payload = envelope_for(conversation, node_event)
      broadcast_to(conversation, payload) if payload
    rescue StandardError => e
      Cybros::RateLimitedLog.warn(
        "conversation_channel.broadcast_node_event",
        message: {
          msg: "broadcast_node_event_failed",
          conversation_id: conversation&.id&.to_s,
          node_event_id: node_event&.id&.to_s,
          error_class: e.class.name,
          error: Cybros::RateLimitedLog.sanitize(e.message),
        }.to_json
      )
    end

    private

      def envelope_for(conversation, node_event)
        node_id = node_event.node_id.to_s
        return nil if node_id.blank?

        kind = node_event.kind.to_s
        text = node_event.text.to_s

        if kind == "output_compacted" && text.blank?
          output_preview = conversation.output_preview_for_node_id(node_id)
          text = output_preview.fetch("content", "").to_s
        end

        envelope = {
          "type" => "node_event",
          "conversation_id" => conversation.id.to_s,
          "turn_id" => (node_event.respond_to?(:turn_id) ? node_event.turn_id : nil).to_s,
          "node_id" => node_id,
          "event_id" => node_event.id,
          "kind" => kind,
          "text" => text,
          "payload" => node_event.payload || {},
          "occurred_at" => node_event.created_at&.iso8601,
        }

        merge_activity_fields!(envelope, node_event.payload || {})
        envelope
      end

      def merge_activity_fields!(envelope, payload)
        payload = payload.is_a?(Hash) ? payload : {}
        return envelope unless DAG::NodeEvent::ACTIVITY_EVENT_KINDS.include?(envelope["kind"])

        envelope["sequence"] = payload["sequence"]
        envelope["activity_id"] = payload["activity_id"]
        envelope["activity_kind"] = payload["kind"]
        envelope["activity_status"] = payload["status"]
        envelope["activity_phase"] = payload["phase"]
        envelope["source_node_id"] = payload["source_node_id"].to_s if payload["source_node_id"].present?
        envelope["diagnostic_level"] = payload["diagnostic_level"]
        envelope
      end
  end

  private

    def rate_limited_warn(error)
      @last_warn_at ||= Time.at(0)
      now = Time.current
      return if (now - @last_warn_at) < 10

      @last_warn_at = now

      conversation_id = @conversation&.id
      Rails.logger.warn(
        {
          msg: "conversation_channel_poll_error",
          conversation_id: conversation_id&.to_s,
          cursor: @cursor.to_s,
          error_class: error.class.name,
          error: Cybros::RateLimitedLog.sanitize(error.message),
        }.to_json
      )
    rescue StandardError
      nil
    end

    def replay_missed_events!(source:)
      return if @conversation.nil?
      return if @node_id.blank?

      after_cursor = @cursor.to_s
      output_preview = @conversation.output_preview_for_node_id(@node_id)
      turn_id = @conversation.turn_id_for_node_id(@node_id).to_s

      events =
        @conversation.node_event_page_for(
          @node_id,
          after_event_id: @cursor,
          limit: 200,
          kinds: [
            "output_delta",
            "output_compacted",
            "progress",
            "log",
          ],
        )

      if events.empty?
        # On subscribe/reconnect, emit a structured replay log even when no events were missed.
        # (On poll fallback, stay quiet to avoid log spam.)
        if source.to_s == "subscribe"
          Rails.logger.info(
            {
              msg: "conversation_channel_replay",
              event: "replay",
              source: source.to_s,
              conversation_id: @conversation.id.to_s,
              node_id: @node_id.to_s,
              replay_count: 0,
              replay_kinds_counts: {},
              after_cursor: after_cursor,
              cursor: @cursor.to_s,
            }.to_json
          )
        end

        return
      end

      replay_kinds_counts = Hash.new(0)
      batch =
        events.filter_map do |event_hash|
          next unless event_hash.is_a?(Hash)

          kind = event_hash.fetch("kind").to_s
          text = event_hash.fetch("text").to_s
          if kind == "output_compacted" && text.blank?
            text = output_preview.fetch("content", "").to_s
          end
          replay_kinds_counts[kind] += 1

          envelope = {
            "type" => "node_event",
            "conversation_id" => @conversation.id.to_s,
            "turn_id" => turn_id,
            "node_id" => @node_id.to_s,
            "event_id" => event_hash.fetch("event_id"),
            "kind" => kind,
            "text" => text,
            "payload" => event_hash.fetch("payload", {}),
            "occurred_at" => event_hash.fetch("created_at", nil),
          }

          self.class.send(:merge_activity_fields!, envelope, event_hash.fetch("payload", {}))
          envelope
        end

      if batch.any?
        transmit({ "type" => "replay_batch", "events" => batch })
      end

      @cursor = events.last.fetch("event_id").to_s

      Rails.logger.info(
        {
          msg: "conversation_channel_replay",
          event: "replay",
          source: source.to_s,
          conversation_id: @conversation.id.to_s,
          node_id: @node_id.to_s,
          replay_count: batch.length,
          replay_kinds_counts: replay_kinds_counts,
          after_cursor: after_cursor,
          cursor: @cursor.to_s,
        }.to_json
      )
    end
end
