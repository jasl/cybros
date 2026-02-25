ENV["RAILS_ENV"] ||= "test"
# Use "either" territory auth in tests so both header and mTLS fingerprint
# paths can be exercised. Production defaults to "mtls".
ENV["CONDUITS_TERRITORY_AUTH_MODE"] ||= "either"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
