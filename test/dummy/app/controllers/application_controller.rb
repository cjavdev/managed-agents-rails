class ApplicationController < ActionController::Base
  # The dummy app's stand-in for authentication.
  def current_user
    User.find_by(id: cookies[:user_id])
  end
end
