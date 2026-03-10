require "bundler/setup"
require "json"
require "minitest/autorun"
require "net/http"
require "pathname"
require "uri"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |path| require path }
require "cybros/agents/default"

module TestPaths
  module_function

  def source_root
    Pathname.new(File.expand_path("..", __dir__))
  end
end
