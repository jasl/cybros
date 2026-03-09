module System
  module Settings
    class WorkspacesController < BaseController
      before_action :set_workspace, only: %i[show edit update]
      before_action :set_form_inputs, only: :edit

      def index
        @workspaces = Workspace.includes(:execution_location).order(:name, :id)
      end

      def show
        @execution_targets = @workspace.execution_targets.order(:name, :id)
      end

      def edit
      end

      def update
        @workspace.assign_attributes(workspace_attributes_from_params)
        set_form_inputs_from_params

        if @workspace.save
          flash[:notice] = "Workspace updated"
          redirect_to system_settings_workspace_path(@workspace)
          return
        end

        render :edit, status: :unprocessable_entity
      end

      private

        def set_workspace
          @workspace = Workspace.includes(:execution_location).find(params[:id])
        end

        def set_form_inputs
          @status_input = @workspace.status
          @capability_tags_text = format_tags(@workspace.capability_tags)
          @tags_text = format_tags(@workspace.tags)
        end

        def set_form_inputs_from_params
          @status_input = workspace_params.fetch(:status, nil).to_s
          @capability_tags_text = workspace_params.fetch(:capability_tags_text, nil).to_s
          @tags_text = workspace_params.fetch(:tags_text, nil).to_s
        end

        def workspace_attributes_from_params
          raw = workspace_params.permit(:status, :capability_tags_text, :tags_text)

          {
            status: raw[:status],
            capability_tags: parse_tags(raw[:capability_tags_text]),
            tags: parse_tags(raw[:tags_text]),
          }
        end

        def parse_tags(raw_text)
          raw_text.to_s.split(/[\n,]/).map(&:strip).reject(&:blank?).uniq
        end

        def format_tags(values)
          Array(values).join(", ")
        end

        def workspace_params
          params.fetch(:workspace, ActionController::Parameters.new)
        end
    end
  end
end
