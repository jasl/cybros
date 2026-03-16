Rails.application.routes.draw do
  get "health", to: "health#show"
  post "rpc", to: "rpc#create"
end
