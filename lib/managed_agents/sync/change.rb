module ManagedAgents
  class Sync
    Change = Struct.new(:agent_name, :kind, :key, :action, :remote_id)

    module Digests
      module_function

      def canonical(value)
        case value
        when Hash then value.sort_by { |key, _| key.to_s }.to_h { |key, nested| [key.to_s, canonical(nested)] }
        when Array then value.map { |nested| canonical(nested) }
        else value
        end
      end

      def digest(value)
        Digest::SHA256.hexdigest(canonical(value).to_json)[0, 32]
      end

      # Keyed, so a digest stored next to a credential says nothing about the secret.
      def secret_digest(value)
        key = Rails.application.secret_key_base.to_s
        OpenSSL::HMAC.hexdigest("SHA256", key, canonical(value).to_json)[0, 32]
      end
    end
  end
end
