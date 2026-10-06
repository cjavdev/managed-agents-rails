require "socket"
require "uri"

module ManagedAgents
  module OAuth
    # The sign-in flow from a terminal, for `bin/rails managed_agents:connect`.
    # It prints the authorization URL, then takes the callback from whichever
    # comes first: a request to the redirect URI on this machine, or the
    # address the browser landed on, pasted in. Pasting is what makes it work
    # from a remote shell (a Render or Heroku console), where the browser
    # can't reach the process.
    class Terminal
      def initialize(vault, server_url, redirect_uri:, scope: nil, input: $stdin, output: $stdout, listen: true)
        @vault = vault
        @server_url = server_url
        @redirect_uri = redirect_uri
        @scope = scope
        @input = input
        @output = output
        @listen = listen
      end

      def run
        pending = OAuth.authorize(@server_url, redirect_uri: @redirect_uri, scope: @scope)
        @output.puts "Open this address in a browser and approve access to #{@server_url}:"
        @output.puts
        @output.puts "  #{pending.url}"
        @output.puts
        @output.puts "Your browser is then sent to #{@redirect_uri}. If this terminal doesn't pick it up, " \
          "paste the full address the browser shows here and press Enter:"
        OAuth.complete(@vault, pending.to_h, callback_params)
      end

      # The query of a callback URL as the params OAuth.complete takes.
      def self.params_from(url)
        query = URI.parse(url.to_s.strip).query.to_s
        URI.decode_www_form(query).to_h.with_indifferent_access
      rescue URI::InvalidURIError
        raise Rejected, "That is not the address the browser was sent to"
      end

      private

      def callback_params
        results = Queue.new
        server = listener
        threads = []
        threads << Thread.new { results << serve(server) } if server
        threads << Thread.new { results << @input.gets }
        line = results.pop
        raise Rejected, "No callback was received" if line.nil?

        self.class.params_from(line)
      ensure
        threads&.each(&:kill)
        server&.close
      end

      # Listens on the redirect URI's port when it points at this machine.
      def listener
        uri = URI.parse(@redirect_uri)
        return unless @listen && %w[localhost 127.0.0.1].include?(uri.host)

        TCPServer.new((uri.host == "localhost") ? "127.0.0.1" : uri.host, uri.port)
      rescue SystemCallError, SocketError
        nil
      end

      # Answers one browser request and returns the URL it asked for.
      def serve(server)
        loop do
          client = server.accept
          request_line = client.gets.to_s
          path = request_line.split(" ")[1].to_s
          if path.start_with?(URI.parse(@redirect_uri).path)
            client.write "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n" \
              "Signed in. You can close this tab and return to the terminal.\n"
            client.close
            return URI.join(@redirect_uri, path).to_s
          end
          client.write "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n"
          client.close
        end
      end
    end
  end
end
