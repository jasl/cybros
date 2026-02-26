module Settings
  class ProfilesController < BaseController
    def show
      @identity = Current.identity
    end

    def update
      @identity = Current.identity

      email = params.dig(:identity, :email).to_s.strip
      password = params.dig(:identity, :password).to_s
      password_confirmation = params.dig(:identity, :password_confirmation).to_s
      current_password = params.dig(:identity, :current_password).to_s

      wants_email_change = email.present? && email != @identity.email.to_s
      wants_password_change = password.present?

      if wants_email_change || wants_password_change
        unless @identity.authenticate(current_password)
          @identity.errors.add(:current_password, "is invalid")
          render :show, status: :unprocessable_entity
          return
        end
      end

      attrs = {}
      attrs[:email] = email if wants_email_change
      if wants_password_change
        attrs[:password] = password
        attrs[:password_confirmation] = password_confirmation
      end

      if attrs.empty?
        flash[:notice] = "No changes"
        redirect_to settings_profile_path
        return
      end

      if @identity.update(attrs)
        flash[:notice] = "Profile updated"
        redirect_to settings_profile_path
      else
        render :show, status: :unprocessable_entity
      end
    end
  end
end
