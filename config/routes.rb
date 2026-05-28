Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token

  resources :runs, only: [ :index, :show, :new, :create ] do
    member { post :select }
  end

  resources :objects, only: [ :index, :show ], param: :api_name, constraints: { api_name: %r{[^/.]+} } do
    member do
      get :fields
      get "fields/:field_name" => :field, as: :field, constraints: { field_name: %r{[^/.]+} }
    end
  end

  resources :mappings, only: [ :index, :create, :update, :destroy ] do
    collection do
      get :export_values
      post :compute_suggestions
    end
    member { post :split }
    resources :mapping_value_entries, only: [ :index, :create, :destroy ], path: "values", as: :values
  end

  resources :mapping_proposals, only: [] do
    member do
      post :accept
      post :reject
      post :unreject
    end
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
    get :mapping_order
  end

  resources :diffs, only: [ :new, :create, :show ]

  get "up" => "rails/health#show", as: :rails_health_check

  authenticated_admin = ->(request) { AdminConstraint.matches?(request) }
  constraints(authenticated_admin) do
    mount MissionControl::Jobs::Engine, at: "/jobs"
  end

  root to: "runs#index"
end
