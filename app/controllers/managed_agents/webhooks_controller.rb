module ManagedAgents
  class WebhooksController < ActionController::API
    HEADERS = %w[webhook-id webhook-timestamp webhook-signature].freeze

    def create
      # Acknowledged so deliveries aren't retried; nothing is handled while paused.
      return head(:no_content) unless ManagedAgents.enabled?

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
