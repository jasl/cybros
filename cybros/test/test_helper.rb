require "simplecov"
require "fileutils"

# Rails parallel tests can leave multiple named entries in `.resultset.json`.
# Clearing at the start avoids merging stale results across separate `bin/rails test`
# runs (e.g., when the worker count changes), which can otherwise skew coverage.
SimpleCov::ResultMerger.synchronize_resultset do
  FileUtils.mkdir_p(SimpleCov.coverage_path)
  File.write(SimpleCov::ResultMerger.resultset_path, "{}\n")
end

SimpleCov.enable_for_subprocesses true
SimpleCov.start "rails" do
  # Track coverage for app code only
  add_filter "/test/"
  add_filter "/config/"
  add_filter "/db/"
  add_filter "/vendor/"

  # Enforce overall coverage (evaluated on the final merged result) in CI.
  ci_enabled = ENV["CI"].to_s.strip != ""
  minimum_coverage(ci_enabled ? 85 : 0)
end

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "securerandom"

module ActiveSupport
  class TestCase
    # Rails parallel tests use Kernel.fork (not Process.fork), so SimpleCov's
    # enable_for_subprocesses doesn't automatically restart coverage in workers.
    # Hook into Rails' parallelization lifecycle to ensure each worker stores its
    # own result, then the parent process merges them at exit.
    if defined?(ActiveSupport::Testing::Parallelization)
      ActiveSupport::Testing::Parallelization.after_fork_hook do |_worker_id|
        next unless defined?(SimpleCov) && SimpleCov.running

        SimpleCov.at_fork.call(_worker_id)
      end
    end

    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...

    def create_identity!(email: nil, password: "Passw0rd")
      email ||= "user-#{SecureRandom.hex(6)}@example.com"
      Identity.create!(
        email: email,
        password: password,
        password_confirmation: password,
      )
    end

    def create_user!(role: :owner, email: nil, password: "Passw0rd")
      identity = create_identity!(email: email, password: password)
      User.create!(identity: identity, role: role)
    end

    def create_conversation!(user: nil, title: "Chat", metadata: nil)
      user ||= create_user!
      metadata ||= { "agent" => { "agent_profile" => "coding" } }
      Conversation.create!(user: user, title: title, metadata: metadata)
    end
  end
end
