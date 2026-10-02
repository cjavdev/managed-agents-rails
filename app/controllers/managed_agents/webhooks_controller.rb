module ManagedAgents
  class WebhooksController < ActionController::API
    HEADERS = %w[webhook-id webhook-timestamp webhook-signature].freeze

    def create
      event = ManagedAgents.client.beta.webhooks.unwrap(request.raw_post,
        headers: HEADERS.index_with { |name| request.headers[name] },
        key: ManagedAgents.config.webhook_secret)

      WebhookJob.perform_later(event.data.type.to_s, event.data.id)
      head :no_content
    rescue StandardWebhooks::StandardWebhooksError, ArgumentError
      head :bad_request
    end
  end
end
