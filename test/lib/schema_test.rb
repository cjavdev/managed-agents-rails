require "test_helper"

class SchemaTest < ActiveSupport::TestCase
  SCHEMA = {
    "type" => "object",
    "properties" => {
      "priority" => {"type" => "string", "enum" => %w[low high]},
      "count" => {"type" => "integer"},
      "tags" => {"type" => "array", "items" => {"type" => "string"}},
      "owner" => {"type" => "object", "properties" => {"id" => {"type" => "integer"}}, "required" => ["id"]}
    },
    "required" => ["priority"]
  }.freeze

  def problems(input, schema = SCHEMA) = ManagedAgents::Schema.problems(input, schema)

  test "valid input has no problems" do
    assert_empty problems("priority" => "high", "count" => 2, "tags" => ["a"], "owner" => {"id" => 1})
  end

  test "reports missing required keys" do
    assert_equal ["input.priority is required"], problems("count" => 1)
  end

  test "reports wrong types, enum values, array items and nested objects" do
    found = problems("priority" => "urgent", "count" => "2", "tags" => ["a", 3], "owner" => {})

    assert_includes found, "input.priority must be one of low, high"
    assert_includes found, "input.count must be integer"
    assert_includes found, "input.tags[1] must be string"
    assert_includes found, "input.owner.id is required"
  end

  test "unknown keys are allowed unless additionalProperties is false" do
    assert_empty problems("priority" => "low", "extra" => 1)
    assert_equal ["input.extra is not a known property"],
      problems({"priority" => "low", "extra" => 1}, SCHEMA.merge("additionalProperties" => false))
  end

  test "no schema means no checks" do
    assert_empty problems({"anything" => 1}, nil)
  end
end
