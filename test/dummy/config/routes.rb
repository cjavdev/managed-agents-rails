Rails.application.routes.draw do
  resources :agent_sessions, only: [:index, :show, :create] do
    scope module: :agent_sessions do
      resources :messages, only: :create
      resources :confirmations, only: :create
      resource :interrupt, only: :create
    end
  end
  mount ManagedAgents::Engine => "/managed_agents"
end
