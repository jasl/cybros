module Settings
  class BaseController < ApplicationController
    layout "agent"
    before_action :require_authentication
    before_action :set_left_sidebar_mode

    private

      def set_left_sidebar_mode
        @left_sidebar_mode = :settings
      end
  end
end
