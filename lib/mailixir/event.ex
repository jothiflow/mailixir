defmodule Mailixir.Event do
  @moduledoc """
  A provider-agnostic email event, produced by `Mailixir.Webhook.parse/4`
  from a provider's webhook payload.

  ## Types

    * `:accepted` — the provider queued the message
    * `:delivered` — the receiving server accepted it
    * `:deferred` — temporary failure, the provider will retry
    * `:bounced` — permanent or final failure; see `:bounce_type` and `:reason`
    * `:complained` — recipient marked it as spam
    * `:opened`, `:clicked` (with `:url`)
    * `:unsubscribed`
    * `:rejected` — the provider refused to send (suppression list, policy, invalid address)
    * `:other` — anything else; `:raw` holds the provider payload

  `:message_id` is the provider's id for the message — the same value returned
  in `Mailixir.Response.id` at send time where the provider makes that possible.
  `:tags` and `:metadata` echo what was set on the `Mailixir.Email`.
  """

  @type type ::
          :accepted
          | :delivered
          | :deferred
          | :bounced
          | :complained
          | :opened
          | :clicked
          | :unsubscribed
          | :rejected
          | :other

  @type bounce_type :: :hard | :soft | nil

  @enforce_keys [:type, :provider]
  defstruct [
    :type,
    :provider,
    :message_id,
    :recipient,
    :timestamp,
    :reason,
    :bounce_type,
    :url,
    tags: [],
    metadata: %{},
    raw: nil
  ]

  @type t :: %__MODULE__{
          type: type(),
          provider: atom(),
          message_id: String.t() | nil,
          recipient: String.t() | nil,
          timestamp: DateTime.t() | nil,
          reason: String.t() | nil,
          bounce_type: bounce_type(),
          url: String.t() | nil,
          tags: [String.t()],
          metadata: map(),
          raw: term()
        }
end
