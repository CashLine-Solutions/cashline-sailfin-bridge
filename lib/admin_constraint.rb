# Routes constraint that admits a request only when the current session belongs
# to an admin user. Used for gating internal dashboards (Mission Control Jobs, etc).
class AdminConstraint
  def self.matches?(request)
    session_token = request.cookie_jar.signed[:session_id]
    return false if session_token.blank?

    session = Session.find_by(id: session_token)
    session&.user&.admin? || false
  end
end
