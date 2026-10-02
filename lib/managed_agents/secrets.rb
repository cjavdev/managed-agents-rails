module ManagedAgents
  # Resolves secrets for vault credentials and the API key.
  #
  # A path like "linear.mcp_token" is looked up as ENV["LINEAR_MCP_TOKEN"], then
  # credentials.dig(Rails.env, :linear, :mcp_token), then
  # credentials.dig(:linear, :mcp_token).
  module Secrets
    SECRET_FIELDS = %w[token access_token refresh_token client_secret secret_value].freeze

    module_function

    def fetch(path)
      lookup(path) || raise(MissingSecret, "No secret found for #{path.inspect}. " \
        "Set ENV[#{env_name(path).inspect}] or add it with `bin/rails credentials:edit`.")
    end

    def lookup(path)
      keys = path.to_s.split(".").map(&:to_sym)
      ENV[env_name(path)].presence || credentials_dig(Rails.env.to_sym, *keys) || credentials_dig(*keys)
    end

    # Resolves `{credential: "a.b"}` / `{env: "NAME"}` references anywhere in a
    # credential's `auth` hash. Literal values in secret fields are refused so a
    # secret can't be committed in a definition file.
    def resolve(value, field: nil)
      case value
      when Hash
        value = value.transform_keys(&:to_s)
        return reference(value) if reference?(value)
        value.to_h { |key, nested| [key, resolve(nested, field: key)] }
      when Array
        value.map { |nested| resolve(nested, field: field) }
      else
        if SECRET_FIELDS.include?(field.to_s)
          raise DefinitionError, "#{field} must be a reference such as {credential: \"service.key\"} " \
            "or {env: \"NAME\"}, not a literal value"
        end
        value
      end
    end

    def reference?(hash)
      hash.size == 1 && (hash.key?("credential") || hash.key?("env"))
    end

    def reference(hash)
      if hash.key?("credential")
        fetch(hash["credential"])
      else
        ENV[hash["env"]].presence || raise(MissingSecret, "ENV[#{hash["env"].inspect}] is not set")
      end
    end

    def env_name(path)
      path.to_s.tr(".", "_").upcase
    end

    def credentials_dig(*keys)
      value = Rails.application.credentials.dig(*keys)
      value.presence unless value.is_a?(Hash)
    rescue ActiveSupport::MessageEncryptor::InvalidMessage, ActiveSupport::EncryptedFile::MissingKeyError
      nil
    end
  end
end
