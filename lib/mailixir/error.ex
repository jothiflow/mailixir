defmodule Mailixir.Error do
  @moduledoc """
  Normalised error returned by every adapter.

  `:reason` is one of:

    * `:invalid_email` — the `Mailixir.Email` failed validation before sending
    * `:invalid_config` — required adapter configuration is missing
    * `:api_error` — the provider answered with an error status (see `:status`, `:details`)
    * `:transport` — the HTTP request itself failed (see `:details`)
    * `:unsupported` — the email uses a feature the adapter cannot express
    * `:batch_failure` — some emails in a `Mailixir.deliver_many/2` call failed;
      `:details` holds the per-email results in order
    * `:invalid_signature` — a webhook's signature did not verify (`Mailixir.Webhook`)
    * `:invalid_payload` — a webhook body could not be decoded or has an unexpected shape
  """

  defexception [:reason, :message, :provider, :status, details: nil]

  @type reason ::
          :invalid_email
          | :invalid_config
          | :api_error
          | :transport
          | :unsupported
          | :batch_failure
          | :invalid_signature
          | :invalid_payload

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          provider: atom() | nil,
          status: pos_integer() | nil,
          details: term()
        }

  @impl true
  def message(%__MODULE__{message: message, provider: nil}), do: message
  def message(%__MODULE__{message: message, provider: provider}), do: "[#{provider}] #{message}"

  @doc """
  Whether this error proves the provider did not accept the message.

  True only for an `:unsupported` error, a connection-phase failure, HTTP
  429, or HTTP 503. An adapter returns `:unsupported` before making any
  request, when it cannot express what the email asks for (for example
  `list_unsubscribe: :none` on Brevo), so the next provider may try. A
  connection-phase failure is one of:

    * the connection was refused (`:econnrefused`)
    * DNS failed (`:nxdomain`)
    * the host or network was unreachable (`:ehostunreach`, `:enetunreach`)
    * the TLS handshake failed (`{:tls_alert, _}`, `:protocol_not_negotiated`,
      `{:bad_alpn_protocol, _}`)

  Anything else returns false, including a timeout. Req 0.5, Finch and Mint
  report a connect timeout and a receive timeout as the same
  `Req.TransportError` reason, `:timeout` ("a timeout in interacting with
  the socket"), so the two cannot be told apart. `:closed` and
  `:econnreset` can also arrive after the request was written, and a 5xx
  other than 503 can mean the provider accepted the message and then failed.
  In those cases the caller retries the *same* provider with the *same*
  idempotency key. Failing over would risk sending the email twice, because
  the next provider cannot deduplicate it.

  `Mailixir.Adapters.Fallback` uses this as its default policy. A `:transport`
  error's `:details` is the underlying exception (`Req.TransportError`,
  `Mint.TransportError` or `Finch.TransportError`) or, for SMTP, a
  `{:network_failure, host, {:error, reason}}` tuple from gen_smtp.
  """
  @spec not_accepted?(t()) :: boolean()
  def not_accepted?(%__MODULE__{reason: :unsupported}), do: true
  def not_accepted?(%__MODULE__{reason: :api_error, status: status}) when status in [429, 503], do: true

  def not_accepted?(%__MODULE__{reason: :transport, details: details}) do
    connection_failure?(failure_reason(details))
  end

  def not_accepted?(%__MODULE__{}), do: false

  @doc """
  The transport failure carried in `:details`, or `nil` when there is none.

  `not_accepted?/1` is what decides a failover. This is the reason itself
  (`:econnrefused`, `:timeout`, `{:tls_alert, _}`, ...) for a log or a
  record, so a caller does not match on `Req` or Mint structs in `:details`.
  """
  @spec transport_reason(t()) :: term()
  def transport_reason(%__MODULE__{reason: :transport, details: details}), do: failure_reason(details)
  def transport_reason(%__MODULE__{}), do: nil

  @doc false
  @spec new(reason(), String.t(), keyword()) :: t()
  def new(reason, message, opts \\ []) do
    struct!(__MODULE__, [reason: reason, message: message] ++ opts)
  end

  @connection_reasons [
    :econnrefused,
    :nxdomain,
    :ehostunreach,
    :enetunreach,
    :protocol_not_negotiated
  ]

  defp connection_failure?(reason) when reason in @connection_reasons, do: true
  defp connection_failure?({:tls_alert, _}), do: true
  defp connection_failure?({:bad_alpn_protocol, _}), do: true
  defp connection_failure?(_reason), do: false

  defp failure_reason(%{reason: reason}), do: reason
  defp failure_reason({:network_failure, _host, {:error, reason}}), do: reason
  defp failure_reason({:network_failure, {:error, reason}}), do: reason
  defp failure_reason(_details), do: nil
end
