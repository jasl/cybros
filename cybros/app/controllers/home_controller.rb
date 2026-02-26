class HomeController < ApplicationController
  layout "landing"

  def index
    if Identity.none?
      redirect_to new_setup_path
      return
    end

    redirect_to dashboard_path if authenticated?
  end
end
