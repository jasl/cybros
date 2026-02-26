# frozen_string_literal: true

class ConversationsController < ApplicationController
  before_action :require_authentication
  before_action :set_conversation, only: %i[show]

  def index
    @conversations = Conversation.order(created_at: :desc)
  end

  def create
    title = params.dig(:conversation, :title).to_s.strip
    title = "Conversation" if title.blank?

    conversation =
      Conversation.create!(
        title: title,
        metadata: { "agent" => { "agent_profile" => "coding" } },
      )

    redirect_to conversation_path(conversation)
  end

  def show
    graph = @conversation.dag_graph
    lane = graph.main_lane
    leaf = graph.leaf_nodes.where(lane_id: lane.id).order(:id).last

    @transcript = leaf ? graph.transcript_for(leaf.id) : []
    @streaming_node_id = leaf&.id
  end

  private
    def set_conversation
      @conversation = Conversation.find(params[:id])
    end
end

