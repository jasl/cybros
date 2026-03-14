ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "json"
require "net/http"
require "pathname"
require "uri"

require_relative "support/contract_assertions"
require_relative "support/callback_harness"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    include TestSupport::ContractAssertions

    # Add more helper methods to be used by all tests here...
  end
end

module TestPaths
  module_function

  def source_root
    Rails.root
  end
end
