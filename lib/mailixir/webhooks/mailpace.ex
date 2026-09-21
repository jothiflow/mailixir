defmodule Mailixir.Webhooks.MailPace do
  @moduledoc """
  Parses [MailPace webhooks](https://docs.mailpace.com/guide/webhooks)
  (`{"event": "email.*", "payload": {...}}`, one `Mailixir.Event` per recipient).

  Verification: pass `public_key:` (the base64 Ed25519 key from the MailPace
  dashboard); the `X-MailPace-Signature` header is checked over the raw body.

  `message_id` is the payload `id`, matching `Mailixir.Adapters.MailPace`.
  """

  use Mailixir.Webhook, provider: :mailpace

  @impl true
  def verify(raw_body, _decoded, headers, config) do
    case Keyword.get(config, :public_key) do
      nil -> :ok
      key -> verify_signature(raw_body, header(headers, "x-mailpace-signature"), key)
    end
  end

  defp verify_signature(raw_body, signature, key) when is_binary(signature) do
    with {:ok, public_key} <- Base.decode64(key),
         {:ok, signature} <- Base.decode64(signature),
         true <- :crypto.verify(:eddsa, :none, raw_body, signature, [public_key, :ed25519]) do
      :ok
    else
      _ -> {:error, Mailixir.Webhook.invalid_signature(provider())}
    end
  end

  defp verify_signature(_raw_body, nil, _key) do
    {:error, Mailixir.Webhook.invalid_signature(provider(), "missing X-MailPace-Signature header")}
  end

  @impl true
  def parse(%{"event" => name, "payload" => %{} = payload}, _config) do
    {type, bounce_type} = classify(name, payload["status"])

    events =
      for recipient <- recipients(payload["to"]) do
        event(provider(),
          type: type,
          bounce_type: bounce_type,
          message_id: payload["id"] && to_string(payload["id"]),
          recipient: recipient,
          timestamp: iso8601(payload["updated_at"] || payload["created_at"]),
          reason: payload["reason"] || payload["status_reason"],
          tags: List.wrap(payload["tags"]),
          raw: payload
        )
      end

    {:ok, events}
  end

  def parse(_decoded, _config), do: {:error, invalid(provider(), "expected event and payload fields")}

  defp classify("email.queued", _), do: {:accepted, nil}
  defp classify("email.delivered", _), do: {:delivered, nil}
  defp classify("email.deferred", _), do: {:deferred, nil}
  defp classify("email.bounced", "softbounced"), do: {:bounced, :soft}
  defp classify("email.bounced", _), do: {:bounced, :hard}
  defp classify("email.spam", _), do: {:complained, nil}
  defp classify(_, _), do: {:other, nil}

  defp recipients(to) when is_binary(to),
    do: to |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp recipients(to) when is_list(to), do: to
  defp recipients(_), do: [nil]
end
