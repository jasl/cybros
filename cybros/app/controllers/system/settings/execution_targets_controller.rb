module System
  module Settings
    class ExecutionTargetsController < BaseController
      before_action :set_execution_target, only: :show

      def index
        @execution_targets = ExecutionTarget.includes(:execution_location, :workspace).order(:name, :id)
      end

      def show
      end

      private

        def set_execution_target
          @execution_target = ExecutionTarget.includes(:execution_location, :workspace).find(params[:id])
        end
    end
  end
end
