module System
  module Settings
    class BaseController < ApplicationController
      layout "agent"
      before_action :require_authentication
      before_action :set_left_sidebar_mode
      before_action :require_system_settings_access

      private
        def set_left_sidebar_mode
          @left_sidebar_mode = :settings
        end

        def require_system_settings_access
          return if Current.user&.owner? || Current.user&.admin?
          head :forbidden
        end
    end
  end
end
