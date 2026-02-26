module Settings
  class BaseController < ApplicationController
    layout "settings"
    before_action :require_authentication
  end
end
