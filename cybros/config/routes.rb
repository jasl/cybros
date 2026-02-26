Rails.application.routes.draw do
  get "home/index"
  resource :setup, only: %i[new create]
  resource :session, only: %i[new create destroy]

  get "dashboard", to: "dashboard#show"

  namespace :settings do
    resource :profile, only: %i[show update]
    resource :sessions, only: %i[show destroy]
  end

  namespace :system do
    namespace :settings do
      resources :llm_providers, only: %i[index new create edit update destroy] do
        post :fetch_models, on: :member
      end
      resources :agent_programs, only: %i[index new create show]
    end
  end

  resources :agent_programs, only: %i[index new create show]
  resources :conversations, only: %i[index show create] do
    resources :messages, only: %i[index create], controller: "conversation_messages"
    post :stop, on: :member
    post :retry, on: :member
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
