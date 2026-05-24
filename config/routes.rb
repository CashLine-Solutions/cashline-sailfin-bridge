Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  # Mission Control Jobs dashboard — gated to admins by AdminConstraint (defined in lib/admin_constraint.rb)
  authenticated_admin = ->(request) { AdminConstraint.matches?(request) }
  constraints(authenticated_admin) do
    mount MissionControl::Jobs::Engine, at: "/jobs"
  end

  # Placeholder root — Phase E will replace this with a dashboard / runs index.
  root to: "rails/health#show"
end
