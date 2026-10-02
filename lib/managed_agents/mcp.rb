require "uri"

module ManagedAgents
  # The MCP servers the app's agents declare, and URL matching.
  module MCP
    Server = Struct.new(:name, :url, :agents) do
      def key = MCP.normalize(url)
    end

    module_function

    # Credentials are matched to servers by URL the way the API does it:
    # scheme and host are case-insensitive, and default ports and a trailing
    # slash don't count.
    def normalize(url)
      uri = URI.parse(url.to_s.strip)
      return url.to_s unless uri.is_a?(URI::HTTP) && uri.host

      port = (uri.port == uri.default_port) ? "" : ":#{uri.port}"
      path = uri.path.to_s.chomp("/")
      query = uri.query ? "?#{uri.query}" : ""
      "#{uri.scheme.downcase}://#{uri.host.downcase}#{port}#{path}#{query}"
    rescue URI::InvalidURIError
      url.to_s
    end

    # Every server declared in an agent.md, once per URL.
    def servers(definitions = ManagedAgents.definitions)
      definitions.each_with_object({}) do |definition, found|
        Array(definition.agent.data["mcp_servers"]).each do |server|
          entry = found[normalize(server["url"])] ||= Server.new(server["name"], server["url"], [])
          entry.agents << definition.name
        end
      end.values
    end

    def server(url)
      servers.find { |server| server.key == normalize(url) }
    end
  end
end
