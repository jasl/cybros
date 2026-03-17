Rails.application.routes.draw do
  get "home/index"
  resource :setup, only: %i[new create]
  resource :session, only: %i[new create destroy]

  get "dashboard", to: "dashboard#show"
  get "statistics", to: "statistics#show"
  get "sidebar_conversations", to: "sidebar_conversations#index"

  namespace :settings do
    resource :profile, only: %i[show update]
    resource :sessions, only: %i[show destroy]
  end

  namespace :system do
    namespace :settings do
      resources :llm_providers, only: %i[index edit update], param: :provider_key do
        patch :default_model, on: :collection
        post :device_flow_start, on: :member
        post :device_flow_poll, on: :member
      end
      resource :runtime_settings, only: %i[show edit update]
      resource :runtime_governance, only: :show, controller: "runtime_governance"
      resources :automations, only: %i[index show] do
        resources :executions, only: [], controller: "automation_executions" do
          post :approve, on: :member
          post :reject, on: :member
        end
      end
    end
  end

  post "agent_rpc/callbacks/:scope_type/:scope_id", to: "agent_rpc/callbacks#create", as: :agent_rpc_callback

  resources :conversations, only: %i[index show create update] do
    resource :composer_draft, only: :update, controller: "conversation_composer_drafts"
    get :composer_status, on: :member
    post :branch, on: :member
    post :regenerate, on: :member
    post :swipe, on: :member
    post :clear_translations, on: :member

    resources :nodes, only: %i[destroy], controller: "conversation_nodes" do
      post :exclude, on: :member
      post :include, on: :member
      post :restore, on: :member
      post :translate, on: :member
    end

    resources :messages, only: %i[index create], controller: "conversation_messages" do
      get :refresh, on: :collection
    end
    resources :queue_items, only: %i[destroy], controller: "conversation_queue_items", param: :queued_user_node_id do
      post :edit, on: :member
      post :steer, on: :member
    end
    post :stop, on: :member
    post :start, on: :member
    post :approve, on: :member
    post :retry, on: :member
    post :steer_current_turn, on: :member
  end

  # OpenAI-compatible mock LLM API for development/testing.
  if Rails.env.development? || Rails.env.test?
    namespace :mock_llm do
      namespace :v1 do
        post "chat/completions", to: "chat_completions#create"
        get "models", to: "models#index"
      end
    end
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "home#index"
end
