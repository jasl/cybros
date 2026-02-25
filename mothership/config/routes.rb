Rails.application.routes.draw do
  # Health check for load balancers and uptime monitors.
  get "up" => "rails/health#show", as: :rails_health_check

  # Conduits API: Nexus <-> Mothership communication channel
  namespace :conduits do
    namespace :v1 do
      resources :polls, only: [:create]

      resources :territories, only: [] do
        collection do
          post :enroll
          post :heartbeat
        end
      end

      resources :directives, only: [] do
        member do
          post :started
          post :heartbeat
          post :log_chunks
          post :finished
        end
      end
    end
  end

  # Mothership internal API: user/system facing
  namespace :mothership do
    resources :territories, only: [:index]

    resources :directives, only: [:index, :show] do
      member do
        get :log
        get :diff
      end
    end

    namespace :api do
      namespace :v1 do
        resources :policies

        resources :facilities, only: [] do
          resources :directives, only: [:create, :show, :index],
                    controller: "facility_directives" do
            member do
              get :log_chunks
              post :approve
              post :reject
            end
          end
        end
      end
    end
  end
end
