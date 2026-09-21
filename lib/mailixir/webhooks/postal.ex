defmodule Mailixir.Webhooks.Postal do
  @moduledoc """
  Parses [Postal webhooks](https://docs.postalserver.io/developer/webhooks)
  (one event per request).

  Verification: pass `public_key:` — your Postal server's webhook public key
  in PEM form (`postal default-dkim-record` / the server's "Webhook public
  key"); the `X-Postal-Signature` header is an RSA-SHA1 signature over the
  raw body.

  `message_id` is the message's `message_id` (RFC header value, without
  brackets), matching `Mailixir.Adapters.Postal`.
  """

  use Mailixir.Webhook, provider: :postal

  alias Mailixir.Response

  @impl true
  def verify(raw_body, _decoded, headers, config) do
    case Keyword.get(config, :public_key) do
      nil -> :ok
      pem -> verify_signature(raw_body, header(headers, "x-postal-signature"), pem)
    end
  end

  defp verify_signature(raw_body, signature, pem) when is_binary(signature) do
    with [entry] <- :public_key.pem_decode(pem),
         {:ok, signature} <- Base.decode64(signature),
         true <- :public_key.verify(raw_body, :sha, signature, :public_key.pem_entry_decode(entry)) do
      :ok
    else
      [] -> {:error, Error.new(:invalid_config, "public_key is not a valid PEM", provider: provider())}
      _ -> {:error, Mailixir.Webhook.invalid_signature(provider())}
    end
  end

  defp verify_signature(_raw_body, nil, _pem) do
    {:error, Mailixir.Webhook.invalid_signature(provider(), "missing X-Postal-Signature header")}
  end

  @impl true
  def parse(%{"event" => name, "payload" => %{} = payload} = data, _config) do
    message = payload["message"] || payload["original_message"] || %{}
    {type, bounce_type} = classify(name, payload["status"])

    {:ok,
     [
       event(provider(),
         type: type,
         bounce_type: bounce_type,
         message_id: Response.normalize_id(message["message_id"]),
         recipient: message["to"],
         timestamp: unix(payload["timestamp"] || data["timestamp"]),
         reason: payload["details"] || payload["output"],
         url: payload["url"],
         tags: List.wrap(message["tag"]),
         raw: data
       )
     ]}
  end

  def parse(_decoded, _config), do: {:error, invalid(provider(), "expected event and payload fields")}

  defp classify("MessageSent", _), do: {:delivered, nil}
  defp classify("MessageDelayed", _), do: {:deferred, nil}
  defp classify("MessageDeliveryFailed", "SoftFail"), do: {:bounced, :soft}
  defp classify("MessageDeliveryFailed", _), do: {:bounced, :hard}
  defp classify("MessageBounced", _), do: {:bounced, :hard}
  defp classify("MessageHeld", _), do: {:rejected, nil}
  defp classify("MessageLoaded", _), do: {:opened, nil}
  defp classify("MessageLinkClicked", _), do: {:clicked, nil}
  defp classify(_, _), do: {:other, nil}
end
