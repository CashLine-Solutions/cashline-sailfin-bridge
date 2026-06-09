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

  # Field-level resolution views — complements the edge-per-row mapping grid.
  # by_source: one row per Sailfin field, showing its fate (disposition + targets).
  # by_target: one row per cashline column, showing what feeds it (coverage view).
  get "resolutions/by_source" => "resolutions#by_source", as: :resolutions_by_source
  get "resolutions/by_target" => "resolutions#by_target", as: :resolutions_by_target
  post "resolutions/accept_candidate" => "resolutions#accept_candidate", as: :resolutions_accept_candidate
  get "resolutions" => redirect("/resolutions/by_target"), as: :resolutions

  # Customer grouping review queue — confirm/reject parent roll-ups detected from
  # Sailfin Account names/structure before the importer applies them.
  resources :customer_groupings, only: [ :index ], path: "grouping" do
    collection do
      post :detect
      post :roll_up   # nest many groupings under one customer (bulk)
    end
    member do
      post :confirm
      post :reject
      post :unreject
      post :merge
      post :unmerge
      post :unroll          # remove this grouping from its customer
      patch :group_label    # edit a rolled-up grouping's group label
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

  get "visualizations" => "visualizations#index", as: :visualizations
  get "visualizations/data" => "visualizations#data", as: :visualizations_data

  # /graph was the standalone Cytoscape page; it now lives as the top section
  # of /visualizations. The redirect keeps bookmarked URLs working, and the
  # `graph_path` helper still resolves (used by older internal links).
  get "graph" => redirect("/visualizations"), as: :graph

  namespace :reports do
    get :hub_orphan
    get :unused_fields
    get :mapping_order
    get :picklists
    get :record_types
  end

  resources :diffs, only: [ :new, :create, :show ]

  get "up" => "rails/health#show", as: :rails_health_check

  authenticated_admin = ->(request) { AdminConstraint.matches?(request) }
  constraints(authenticated_admin) do
    mount MissionControl::Jobs::Engine, at: "/jobs"
  end

  root to: "runs#index"
end
