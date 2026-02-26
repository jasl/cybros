class HomeController < ApplicationController
  before_action :bootstrap_or_require_auth

  def index
  end

  private

    def bootstrap_or_require_auth
      if Identity.none?
        redirect_to new_setup_path
        return
      end

      require_authentication
    end
end
