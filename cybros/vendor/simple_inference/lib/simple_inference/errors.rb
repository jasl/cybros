# frozen_string_literal: true

module SimpleInference
  class Error < StandardError; end

  class ValidationError < Error; end

  class ConfigurationError < ValidationError; end

  class HTTPError < Error
    attr_reader :response

    def initialize(message, response:)
      super(message)
      @response = response
    end

    def status = @response.status

    def headers = @response.headers

    def body = @response.body

    def raw_body = @response.raw_body
  end

  class TimeoutError < Error; end
  class ConnectionError < Error; end
  class DecodeError < Error; end
end
