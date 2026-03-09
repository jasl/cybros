require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  if ENV["CAPYBARA_SERVER_PORT"]
    served_by host: "rails-app", port: ENV["CAPYBARA_SERVER_PORT"]

    driven_by :selenium, using: :headless_chrome, screen_size: [1400, 1400], options: {
      browser: :remote,
      url: "http://#{ENV["SELENIUM_HOST"]}:4444",
    }
  else
    driven_by :selenium, using: :headless_chrome, screen_size: [1400, 1400]
  end

  private

    def sign_in_as!(email:, password: "Passw0rd")
      visit new_session_path

      find("input[name='email']", visible: true).set(email)

      password_field = find("input[name='password']", visible: true)
      password_field.set(password)

      if password_field.value != password
        page.execute_script(<<~JS, password_field, password)
          const [field, value] = arguments;
          field.value = value;
          field.dispatchEvent(new Event("input", { bubbles: true }));
          field.dispatchEvent(new Event("change", { bubbles: true }));
        JS
      end

      assert_equal password, password_field.value

      click_button "Sign in"
      assert_current_path dashboard_path
    end
end
