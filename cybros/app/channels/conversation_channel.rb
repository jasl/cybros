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
      lane = @conversation.dag_graph.main_lane
      leaf = @conversation.dag_graph.leaf_nodes.where(lane_id: lane.id).order(:id).last
      @node_id = leaf&.id&.to_s
    end

    if @cursor.blank? && @node_id.present?
      lane = @conversation.dag_graph.main_lane
      node = lane.graph.nodes.find_by(id: @node_id)
      preview = node&.body_output_preview
      preview = preview.is_a?(Hash) ? preview : {}

      if preview.fetch("content", "").to_s.present?
        @cursor =
          lane
            .node_event_scope_for(@node_id)
            .order(id: :desc)
            .limit(1)
            .pick(:id)
            &.to_s
      end
    end

    Rails.logger.info(
      {
        msg: "conversation_channel_subscribed",
        conversation_id: @conversation.id.to_s,
        node_id: @node_id.to_s,
        cursor: @cursor.to_s,
      }.to_json
    )

    replay_missed_events!
  end

  def poll_fallback
    replay_missed_events!
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
        node = node_event.node
        return nil if node.nil?

        kind = node_event.kind.to_s
        text = node_event.text.to_s

        if kind == DAG::NodeEvent::OUTPUT_COMPACTED && text.blank?
          output_preview = DAG::NodeBody.where(id: node.body_id).pick(:output_preview)
          output_preview = output_preview.is_a?(Hash) ? output_preview : {}
          text = output_preview.fetch("content", "").to_s
        end

        {
          "type" => "node_event",
          "conversation_id" => conversation.id.to_s,
          "turn_id" => node.turn_id.to_s,
          "node_id" => node.id.to_s,
          "event_id" => node_event.id,
          "kind" => kind,
          "text" => text,
          "payload" => node_event.payload || {},
          "occurred_at" => node_event.created_at&.iso8601,
        }
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

    def replay_missed_events!
      return if @conversation.nil?
      return if @node_id.blank?

      lane = @conversation.dag_graph.main_lane
      node = lane.graph.nodes.find_by(id: @node_id)
      output_preview = DAG::NodeBody.where(id: node&.body_id).pick(:output_preview)
      output_preview = output_preview.is_a?(Hash) ? output_preview : {}

      events =
        lane.node_event_page_for(
          @node_id,
          after_event_id: @cursor,
          limit: 200,
          kinds: [
            DAG::NodeEvent::OUTPUT_DELTA,
            DAG::NodeEvent::OUTPUT_COMPACTED,
            DAG::NodeEvent::PROGRESS,
            DAG::NodeEvent::LOG,
          ],
        )

      return if events.empty?

      batch =
        events.filter_map do |event_hash|
          next unless event_hash.is_a?(Hash)

          kind = event_hash.fetch("kind").to_s
          text = event_hash.fetch("text").to_s
          if kind == DAG::NodeEvent::OUTPUT_COMPACTED && text.blank?
            text = output_preview.fetch("content", "").to_s
          end

          {
            "type" => "node_event",
            "conversation_id" => @conversation.id.to_s,
            "turn_id" => node&.turn_id.to_s,
            "node_id" => @node_id.to_s,
            "event_id" => event_hash.fetch("event_id"),
            "kind" => kind,
            "text" => text,
            "payload" => event_hash.fetch("payload", {}),
            "occurred_at" => event_hash.fetch("created_at", nil),
          }
        end

      if batch.any?
        transmit({ "type" => "replay_batch", "events" => batch })
      end

      @cursor = events.last.fetch("event_id").to_s

      Rails.logger.info(
        {
          msg: "conversation_channel_replay",
          conversation_id: @conversation.id.to_s,
          node_id: @node_id.to_s,
          replay_count: events.length,
          cursor: @cursor.to_s,
        }.to_json
      )
    end
end
