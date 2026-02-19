TEST_COVERAGE_ENABLED = ENV["CI"].to_s.strip != "" || ENV["COVERAGE"].to_s.strip != ""

if TEST_COVERAGE_ENABLED
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
end

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

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

    # Default to a single process for speed and determinism (especially with coverage enabled).
    # Opt into parallelization via `PARALLEL_WORKERS`.
    parallel_workers =
      if ENV["PARALLEL_WORKERS"].to_s.strip != ""
        Integer(ENV.fetch("PARALLEL_WORKERS"))
      else
        1
      end

    parallelize(workers: parallel_workers) if parallel_workers > 1

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
