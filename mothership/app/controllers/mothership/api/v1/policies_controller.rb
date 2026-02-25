module Mothership
  module API
    module V1
      class PoliciesController < BaseController
        before_action :set_policy, only: %i[show update destroy]

        # GET /mothership/api/v1/policies
        #
        # List policies for the current account.
        # Optional filters: scope_type, scope_id
        def index
          scope = Conduits::Policy.where(account: @current_account)
          scope = scope.where(scope_type: params[:scope_type]) if params[:scope_type].present?
          scope = scope.where(scope_id: params[:scope_id]) if params[:scope_id].present?
          scope = scope.active unless params[:include_inactive] == "true"

          policies = scope.by_priority

          render json: { policies: policies.map { |p| policy_json(p) } }
        end

        # GET /mothership/api/v1/policies/:id
        def show
          render json: policy_json(@policy)
        end

        # POST /mothership/api/v1/policies
        def create
          policy = Conduits::Policy.new(policy_params)
          policy.account = @current_account

          if policy.save
            render json: policy_json(policy), status: :created
          else
            render json: { error: "validation_failed", details: policy.errors.full_messages },
                   status: :unprocessable_entity
          end
        end

        # PATCH/PUT /mothership/api/v1/policies/:id
        def update
          if @policy.update(policy_params)
            render json: policy_json(@policy)
          else
            render json: { error: "validation_failed", details: @policy.errors.full_messages },
                   status: :unprocessable_entity
          end
        end

        # DELETE /mothership/api/v1/policies/:id
        #
        # Soft-delete: sets active to false.
        def destroy
          @policy.update!(active: false)

          render json: { id: @policy.id, active: false }
        end

        private

        def set_policy
          @policy = Conduits::Policy.where(account: @current_account).find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "not_found", detail: "policy not found" }, status: :not_found
        end

        def policy_params
          permitted = params.permit(
            :name, :priority, :scope_type, :scope_id, :active,
            fs: {}, net: {}, secrets: {}, sandbox_profile_rules: {}, approval: {}
          )

          # Convert ActionController::Parameters to plain hashes for JSONB columns
          %w[fs net secrets sandbox_profile_rules approval].each do |key|
            permitted[key] = permitted[key].to_unsafe_h if permitted[key].respond_to?(:to_unsafe_h)
          end

          permitted
        end

        def policy_json(policy)
          {
            id: policy.id,
            name: policy.name,
            priority: policy.priority,
            active: policy.active,
            scope_type: policy.scope_type,
            scope_id: policy.scope_id,
            fs: policy.fs,
            net: policy.net,
            secrets: policy.secrets,
            sandbox_profile_rules: policy.sandbox_profile_rules,
            approval: policy.approval,
            created_at: policy.created_at,
            updated_at: policy.updated_at,
          }
        end
      end
    end
  end
end
