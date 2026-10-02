module ManagedAgents
  module Tool
    Result = Struct.new(:text, :error) do
      def error? = !!error
    end

    # Whatever a handler returns becomes the text the agent reads.
    def self.result(value)
      case value
      when Result then value
      when String then Result.new(value, false)
      when nil then Result.new("ok", false)
      else Result.new(value.to_json, false)
      end
    end

    def self.error(message)
      Result.new(message.to_s, true)
    end
  end
end
