# frozen_string_literal: true

class ConversationChannel < ApplicationCable::Channel
  include ActionCable::Channel::PeriodicTimers

  periodically :poll, every: 0.25

  def subscribed
    identity_id = connection.respond_to?(:current_identity_id) ? connection.current_identity_id : nil
    reject if identity_id.blank?

    @conversation = Conversation.find_by(id: params[:conversation_id])
    reject if @conversation.nil?

    @after_event_id = nil
    @last_node_id = nil

    # Avoid duplicating server-rendered output_preview: start streaming from "now".
    lane = @conversation.dag_graph.main_lane
    leaf = @conversation.dag_graph.leaf_nodes.where(lane_id: lane.id).order(:id).last
    @last_node_id = leaf&.id

    if @last_node_id
      preview = leaf&.body_output_preview
      preview = preview.is_a?(Hash) ? preview : {}

      if preview.fetch("content", "").to_s.present?
        @after_event_id =
          lane
            .node_event_scope_for(@last_node_id)
            .order(id: :desc)
            .limit(1)
            .pick(:id)
      end
    end
  end

  def poll
    lane = @conversation.dag_graph.main_lane
    leaf = @conversation.dag_graph.leaf_nodes.where(lane_id: lane.id).order(:id).last
    return if leaf.nil?

    node_id = leaf.id

    if @last_node_id.to_s != node_id.to_s
      @last_node_id = node_id
      preview = leaf.body_output_preview
      preview = preview.is_a?(Hash) ? preview : {}

      if preview.fetch("content", "").to_s.present?
        @after_event_id =
          lane
            .node_event_scope_for(node_id)
            .order(id: :desc)
            .limit(1)
            .pick(:id)
      else
        @after_event_id = nil
      end
    end

    events =
      lane.node_event_page_for(
        node_id,
        after_event_id: @after_event_id,
        limit: 200,
        kinds: [
          DAG::NodeEvent::OUTPUT_DELTA,
          DAG::NodeEvent::OUTPUT_COMPACTED,
          DAG::NodeEvent::PROGRESS,
          DAG::NodeEvent::LOG,
        ],
      )

    return if events.empty?

    # If retention compacts deltas quickly, we may only see an OUTPUT_COMPACTED
    # marker event. For Phase 0 UI, include the current output_preview content
    # as event.text so the client can render it.
    preview = leaf.body_output_preview
    preview = preview.is_a?(Hash) ? preview : {}
    compacted_text = preview.fetch("content", "").to_s
    if compacted_text.present?
      events =
        events.map do |event|
          next event unless event.is_a?(Hash)
          next event unless event.fetch("kind", nil).to_s == DAG::NodeEvent::OUTPUT_COMPACTED
          next event unless event.fetch("text", "").to_s.blank?

          event.merge("text" => compacted_text)
        end
    end

    @after_event_id = events.last.fetch("event_id")

    transmit(
      {
        "type" => "node_events",
        "node_id" => node_id,
        "after_event_id" => @after_event_id,
        "events" => events,
      }
    )
  rescue StandardError => e
    rate_limited_warn(e)
    nil
  end

  private
    def rate_limited_warn(error)
      @last_warn_at ||= Time.at(0)
      now = Time.current
      return if (now - @last_warn_at) < 10

      @last_warn_at = now

      conversation_id = @conversation&.id
      Rails.logger.warn(
        "ConversationChannel poll error conversation_id=#{conversation_id} after_event_id=#{@after_event_id} error=#{error.class}: #{error.message}"
      )
    rescue StandardError
      nil
    end
end

