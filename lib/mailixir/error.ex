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

  @doc false
  @spec new(reason(), String.t(), keyword()) :: t()
  def new(reason, message, opts \\ []) do
    struct!(__MODULE__, [reason: reason, message: message] ++ opts)
  end
end
