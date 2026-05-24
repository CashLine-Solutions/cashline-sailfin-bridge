Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token

  resources :runs, only: [ :index, :show, :new, :create ] do
    member { post :select }
  end

  resources :objects, only: [ :index, :show ], param: :api_name, constraints: { api_name: %r{[^/.]+} } do
    member { get :fields }
  end

  resources :erds, only: [ :index, :show ], param: :slug, constraints: { slug: %r{[^/.]+} }
  resources :clusters, only: [] do
    collection { get :edit }
    member do
      patch :rename
      patch :assign
      post :reset
    end
  end

  resource :graph, only: [ :show ], controller: "graph" do
    get :data, on: :collection
  end

  namespace :reports do
    get :hub_orphan
    get :unused_fields
  end

  resources :diffs, only: [ :new, :create, :show ]

  get "up" => "rails/health#show", as: :rails_health_check

  authenticated_admin = ->(request) { AdminConstraint.matches?(request) }
  constraints(authenticated_admin) do
    mount MissionControl::Jobs::Engine, at: "/jobs"
  end

  root to: "runs#index"
end
