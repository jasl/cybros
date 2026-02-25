module Mothership
  class TerritoriesController < ApplicationController
    def index
      scope = Conduits::Territory.order(created_at: :desc)
      scope = scope.where(account_id: params[:account_id]) if params[:account_id].present?

      @territories = scope
    end
  end
end
