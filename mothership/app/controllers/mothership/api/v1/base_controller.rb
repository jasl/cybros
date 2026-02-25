module Mothership
  module API
    module V1
      class BaseController < ActionController::API
        before_action :authenticate_user!

        private

        def authenticate_user!
          account_id = request.headers["X-Account-Id"].to_s.presence
          user_id = request.headers["X-User-Id"].to_s.presence

          unless account_id.present? && user_id.present?
            render json: { error: "unauthorized", detail: "X-Account-Id and X-User-Id headers required" },
                   status: :unauthorized
            return
          end

          @current_account = Account.find_by(id: account_id)
          unless @current_account
            render json: { error: "unauthorized", detail: "unknown account" }, status: :unauthorized
            return
          end

          # Verify user belongs to the claimed account (defense-in-depth)
          @current_user = @current_account.users.find_by(id: user_id)
          unless @current_user
            render json: { error: "unauthorized", detail: "unknown user" }, status: :unauthorized
          end
        end

        def current_user
          @current_user
        end
      end
    end
  end
end
