class ConversationLaneProcessesController < AgentController
  before_action :set_conversation
  before_action :set_lane_process

  def stop
    LaneProcesses::Stopper.call!(lane_process: @lane_process)
    @composer_state = @conversation.composer_state

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          helpers.dom_id(@conversation, :composer_status_rail),
          partial: "conversations/composer_status_rail",
          locals: { conversation: @conversation, composer_state: @composer_state },
        )
      end

      format.html { redirect_to conversation_path(@conversation) }
      format.json { render json: { ok: true } }
    end
  end

  private

    def set_conversation
      @conversation = Current.user.conversations.find(params[:conversation_id])
    end

    def set_lane_process
      @lane_process = @conversation.lane_processes.find(params[:id])
    end
end
