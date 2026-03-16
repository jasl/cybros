require "net/http"
require "nokogiri"
require "uri"

module Cybros
  module Agents
    module Claw
      module Tools
        class WebProvider
          class DisabledError < StandardError; end

          DEFAULT_BACKEND = "duckduckgo_html"
          DEFAULT_SEARCH_COUNT = 5
          MAX_SEARCH_COUNT = 10
          DEFAULT_SEARCH_ENDPOINT = "https://duckduckgo.com/html/"
          DEFAULT_FETCH_MAX_CHARS = 8_000
          DEFAULT_REDIRECT_LIMIT = 3
          USER_AGENT = "Cybros Claw/1.0"

          def initialize(backend:, search_endpoint: nil, user_agent: USER_AGENT)
            @backend = backend.to_s.strip
            @search_endpoint = search_endpoint.to_s.strip.presence || DEFAULT_SEARCH_ENDPOINT
            @user_agent = user_agent.to_s
          end

          def enabled?
            @backend.present? && @backend != "disabled"
          end

          def search(query:, count: DEFAULT_SEARCH_COUNT)
            raise DisabledError, "web tools are disabled" unless enabled?
            raise ArgumentError, "web_search requires query" if query.to_s.strip.empty?

            uri = URI.parse(@search_endpoint)
            query_params = URI.decode_www_form(uri.query.to_s)
            query_params.reject! { |key, _value| key == "q" }
            query_params << ["q", query.to_s]
            uri.query = URI.encode_www_form(query_params)

            response, final_uri = http_get_following_redirects(uri)
            document = Nokogiri::HTML(response.body.to_s)

            {
              "backend" => @backend,
              "query" => query.to_s,
              "results" => parse_search_results(document).first(normalized_result_count(count)),
              "url" => final_uri.to_s,
            }
          end

          def fetch(url:, max_chars: DEFAULT_FETCH_MAX_CHARS)
            raise DisabledError, "web tools are disabled" unless enabled?

            uri = URI.parse(url.to_s)
            ensure_http_uri!(uri)

            response, final_uri = http_get_following_redirects(uri)
            body = normalize_body(response.body.to_s)
            content_type = response["content-type"].to_s

            title, content =
              if html_response?(content_type: content_type, body: body)
                parse_html_page(body, max_chars: normalized_max_chars(max_chars))
              else
                [nil, truncate_text(body, max_chars: normalized_max_chars(max_chars))]
              end

            {
              "url" => final_uri.to_s,
              "title" => title.presence || final_uri.to_s,
              "content" => content,
            }
          end

          private

          def normalized_result_count(value)
            parsed = Integer(value, exception: false) || DEFAULT_SEARCH_COUNT
            parsed = DEFAULT_SEARCH_COUNT if parsed <= 0
            [parsed, MAX_SEARCH_COUNT].min
          end

          def normalized_max_chars(value)
            parsed = Integer(value, exception: false) || DEFAULT_FETCH_MAX_CHARS
            parsed = DEFAULT_FETCH_MAX_CHARS if parsed <= 0
            [parsed, DEFAULT_FETCH_MAX_CHARS].min
          end

          def parse_search_results(document)
            results =
              document.css(".result").filter_map do |node|
                anchor = node.at_css("a.result__a, h2 a, a")
                next if anchor.nil?

                url = anchor["href"].to_s.strip
                title = normalize_text(anchor.text)
                next if url.empty? || title.empty?

                snippet_node = node.at_css(".result__snippet, a.result__snippet, .snippet")

                {
                  "title" => title,
                  "url" => url,
                  "snippet" => normalize_text(snippet_node&.text),
                }
              end

            return results if results.any?

            document.css("a[href]").filter_map do |anchor|
              url = anchor["href"].to_s.strip
              title = normalize_text(anchor.text)
              next if url.empty? || title.empty?

              { "title" => title, "url" => url, "snippet" => "" }
            end
          end

          def parse_html_page(body, max_chars:)
            document = Nokogiri::HTML(body)
            document.css("script, style, noscript").remove
            title = normalize_text(document.at_css("title")&.text)
            container = document.at_css("main, article, body")
            content = normalize_text(container&.text)

            [title, truncate_text(content, max_chars: max_chars)]
          end

          def truncate_text(text, max_chars:)
            value = text.to_s
            return value if value.length <= max_chars

            value.slice(0, max_chars)
          end

          def normalize_body(body)
            body.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
          end

          def normalize_text(text)
            text.to_s.gsub(/\s+/, " ").strip
          end

          def html_response?(content_type:, body:)
            return true if content_type.to_s.downcase.include?("text/html")

            body.lstrip.start_with?("<!DOCTYPE html", "<html", "<HTML")
          end

          def http_get_following_redirects(uri, limit: DEFAULT_REDIRECT_LIMIT)
            ensure_http_uri!(uri)

            response = perform_get(uri)
            return [response, uri] unless response.is_a?(Net::HTTPRedirection)
            raise "too many redirects" if limit <= 0

            location = response["location"].to_s
            raise "redirect location missing" if location.empty?

            redirected = URI.join(uri.to_s, location)
            http_get_following_redirects(redirected, limit: limit - 1)
          end

          def perform_get(uri)
            request = Net::HTTP::Get.new(uri)
            request["User-Agent"] = @user_agent

            Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 10) do |http|
              response = http.request(request)
              raise "web request failed: #{response.code}" unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)

              response
            end
          end

          def ensure_http_uri!(uri)
            scheme = uri.scheme.to_s
            raise ArgumentError, "web URLs must use http or https" unless %w[http https].include?(scheme)
          end
        end
      end
    end
  end
end
