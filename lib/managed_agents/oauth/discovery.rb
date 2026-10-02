module ManagedAgents
  module OAuth
    # Finds where to send a person to authorize access to an MCP server.
    #
    # The server names its authorization server in protected resource metadata
    # (RFC 9728), and that server describes its endpoints in authorization
    # server metadata (RFC 8414). Servers that predate this are assumed to
    # serve the endpoints themselves, at /authorize, /token and /register.
    class Discovery
      Metadata = Struct.new(:issuer, :authorization_endpoint, :token_endpoint, :registration_endpoint, :scopes, keyword_init: true) do
        def to_h = super.stringify_keys
      end

      def initialize(server_url)
        @server_url = server_url
        @uri = URI.parse(server_url)
      end

      def metadata
        resource = protected_resource
        issuer = Array(resource["authorization_servers"]).first || origin(@uri)
        server = authorization_server(issuer)

        Metadata.new(
          issuer: server["issuer"] || issuer,
          authorization_endpoint: server["authorization_endpoint"] || "#{origin(@uri)}/authorize",
          token_endpoint: server["token_endpoint"] || "#{origin(@uri)}/token",
          registration_endpoint: server.key?("authorization_endpoint") ? server["registration_endpoint"] : "#{origin(@uri)}/register",
          scopes: Array(resource["scopes_supported"]).presence
        )
      end

      private

      # An unauthenticated request to the server is answered with a pointer to
      # the metadata. Failing that, it lives at a well-known path.
      def protected_resource
        candidates = [advertised_metadata_url, well_known(@uri, "oauth-protected-resource"), "#{origin(@uri)}/.well-known/oauth-protected-resource"]
        fetch_first(candidates)
      end

      def advertised_metadata_url
        response = HTTP.get(@server_url, "Accept" => "application/json, text/event-stream")
        response.headers["www-authenticate"].to_s[/resource_metadata="([^"]+)"/, 1] if response.status == 401
      rescue Error
        nil
      end

      def authorization_server(issuer)
        uri = URI.parse(issuer)
        fetch_first([
          well_known(uri, "oauth-authorization-server"),
          well_known(uri, "openid-configuration"),
          "#{issuer.chomp("/")}/.well-known/openid-configuration"
        ])
      end

      def fetch_first(urls)
        urls.compact.uniq.each do |url|
          response = HTTP.get(url)
          return response.json if response.ok? && response.json.any?
        rescue Error
          next
        end
        {}
      end

      # https://host/tenant -> https://host/.well-known/<name>/tenant
      def well_known(uri, name)
        "#{origin(uri)}/.well-known/#{name}#{uri.path.to_s.chomp("/")}"
      end

      def origin(uri)
        port = (uri.port == uri.default_port) ? "" : ":#{uri.port}"
        "#{uri.scheme}://#{uri.host}#{port}"
      end
    end
  end
end
