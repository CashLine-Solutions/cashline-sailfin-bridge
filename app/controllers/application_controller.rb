class ApplicationController < ActionController::Base
  include Authentication
  include Pundit::Authorization

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

  # Make the current user available to policies (Pundit's default looks at `current_user`)
  def pundit_user
    Current.user
  end

  private

  def user_not_authorized
    flash[:alert] = "You are not authorized to perform this action."
    redirect_back_or_to(root_path)
  end
end

# Controllers that handle resources should include Pundit's verification callbacks
# explicitly. To opt in, add to the controller:
#
#   after_action :verify_authorized
#   after_action :verify_policy_scoped, only: :index
#
# Authentication controllers (SessionsController, PasswordsController) are
# inherently public and do not authorize through policies.
