module System
  module Settings
    class BaseController < ApplicationController
      layout "settings"
      before_action :require_authentication
      before_action :require_system_settings_access

      private

        def require_system_settings_access
          return if Current.user&.owner? || Current.user&.admin?
          head :forbidden
        end
    end
  end
end
