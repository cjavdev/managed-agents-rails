module ManagedAgents
  # A small JSON Schema check for custom tool input. The API does not enforce a
  # custom tool's input_schema, so handlers would otherwise have to.
  module Schema
    TYPES = {
      "string" => [String],
      "integer" => [Integer],
      "number" => [Numeric],
      "boolean" => [TrueClass, FalseClass],
      "array" => [Array],
      "object" => [Hash],
      "null" => [NilClass]
    }.freeze

    module_function

    def problems(input, schema, at: "input")
      return [] if schema.blank?
      return ["#{at} must be an object"] if schema["type"] == "object" && !input.is_a?(Hash)
      return check_value(input, schema, at) unless input.is_a?(Hash)

      properties = schema["properties"] || {}
      found = Array(schema["required"]).reject { |key| input.key?(key) }.map { |key| "#{at}.#{key} is required" }

      input.each do |key, value|
        if properties.key?(key)
          found.concat(check_value(value, properties[key], "#{at}.#{key}"))
        elsif schema["additionalProperties"] == false
          found << "#{at}.#{key} is not a known property"
        end
      end
      found
    end

    def check_value(value, schema, at)
      types = Array(schema["type"])
      if types.any? && types.none? { |type| TYPES.fetch(type, [Object]).any? { |klass| value.is_a?(klass) } }
        return ["#{at} must be #{types.join(" or ")}"]
      end
      return ["#{at} must be one of #{schema["enum"].join(", ")}"] if schema["enum"] && !schema["enum"].include?(value)

      case value
      when Hash then problems(value, schema, at: at)
      when Array
        schema["items"] ? value.each_with_index.flat_map { |item, index| check_value(item, schema["items"], "#{at}[#{index}]") } : []
      else []
      end
    end
  end
end
