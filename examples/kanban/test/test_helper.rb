ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"
require "managed_agents/testing"

WebMock.disable_net_connect!

module ActiveSupport
  class TestCase
    include ActiveJob::TestHelper
    # Swaps the Anthropic client for an in-memory fake in every test.
    include ManagedAgents::Testing::Helper

    parallelize(workers: 1)
  end
end
