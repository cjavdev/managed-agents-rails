require "net/http"
require "json"

module ManagedAgents
  module OAuth
    # The few requests the flow makes. Only HTTPS is spoken, apart from
    # localhost during development.
    module HTTP
      Response = Struct.new(:status, :headers, :body) do
        def ok? = status.between?(200, 299)

        def json
          parsed = JSON.parse(body.to_s)
          parsed.is_a?(Hash) ? parsed : {}
        rescue JSON::ParserError
          {}
        end
      end

      LOCAL = %w[localhost 127.0.0.1 ::1].freeze

      module_function

      def get(url, headers = {})
        request(Net::HTTP::Get, url, headers)
      end

      def post_json(url, body)
        request(Net::HTTP::Post, url, {"Content-Type" => "application/json"}, body.to_json)
      end

      def post_form(url, params, basic_auth: nil)
        request(Net::HTTP::Post, url, {"Content-Type" => "application/x-www-form-urlencoded"},
          URI.encode_www_form(params.compact), basic_auth: basic_auth)
      end

      def request(verb, url, headers, body = nil, basic_auth: nil)
        uri = URI.parse(url.to_s)
        local = uri.is_a?(URI::HTTP) && LOCAL.include?(uri.host)
        raise Error, "Refusing to use #{url}: OAuth endpoints must be HTTPS" unless uri.is_a?(URI::HTTPS) || local

        request = verb.new(uri, {"Accept" => "application/json"}.merge(headers))
        request.basic_auth(*basic_auth) if basic_auth
        request.body = body if body

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 10) do |http|
          http.request(request)
        end
        Response.new(response.code.to_i, response.to_hash.transform_values(&:first), response.body)
      rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, URI::InvalidURIError => error
        raise Error, "Could not reach #{url}: #{error.message}"
      end
    end
  end
end
