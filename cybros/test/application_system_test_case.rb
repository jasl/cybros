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
      identity = Identity.find_by!("lower(email) = ?", email.to_s.downcase.strip)
      assert identity.authenticate(password), "expected #{email} to authenticate"

      browser_session = Session.start!(identity: identity, ip_address: "127.0.0.1", user_agent: "SystemTest")

      # Browser-submitted sign-in is flaky in headless Chrome for these system
      # tests. Inject the same signed cookie that the controller sets instead.
      visit root_path
      page.driver.browser.manage.delete_all_cookies
      page.driver.browser.manage.add_cookie(name: "session_token", value: signed_session_token_for(browser_session), path: "/")
      visit dashboard_path
      assert_selector "body[data-layout='agent']", wait: 10
    end

    def signed_session_token_for(session)
      request = ActionDispatch::TestRequest.create
      request.cookie_jar.signed[:session_token] = session.id
      request.cookie_jar[:session_token]
    end
end
