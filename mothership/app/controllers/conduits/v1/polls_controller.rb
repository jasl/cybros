module Conduits
  module V1
    class PollsController < Conduits::V1::ApplicationController
      # POST /conduits/v1/polls
      #
      # Params: { supported_sandbox_profiles, max_directives_to_claim }
      # Returns: { directives: [ { directive_id, directive_token, spec } ],
      #            lease_ttl_seconds, retry_after_seconds }
      def create
        profiles = Array(params[:supported_sandbox_profiles]).presence || %w[untrusted]
        max_claims = [(params[:max_directives_to_claim] || 1).to_i, 1].max

        result = Conduits::PollService.new(
          territory: current_territory,
          supported_profiles: profiles,
          max_claims: max_claims
        ).call

        render json: {
          directives: result.directives,
          lease_ttl_seconds: result.lease_ttl_seconds,
          retry_after_seconds: result.retry_after_seconds,
        }
      end
    end
  end
end
