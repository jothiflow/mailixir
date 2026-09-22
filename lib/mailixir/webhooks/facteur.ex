defmodule Mailixir.Webhooks.Facteur do
  @moduledoc """
  Parses [Facteur](https://github.com/jothiflow/facteur) webhooks
  (one event per request).

  Verification: pass `secret:` — the endpoint secret shown when the webhook
  is created or its secret rotated. The `Facteur-Signature` header is
  `t=<unix seconds>,v1=<hex>`, where `v1` is HMAC-SHA256 over
  `"<t>.<raw body>"`; `t` must be within `:tolerance` seconds of now
  (default 300) so a captured request cannot be replayed.

  `message_id` is Facteur's message id — the same value `Mailixir.Response.id`
  carried at send time, not the RFC 5322 Message-ID. Deliveries are
  at-least-once, so dedupe on the event id in `raw["id"]`.

  Facteur reports a soft asynchronous bounce as `deferred`, so a `:bounced`
  event is always `bounce_type: :hard`.
  """

  use Mailixir.Webhook, provider: :facteur

  @header "facteur-signature"
  @default_tolerance 300

  @impl true
  def verify(raw_body, _decoded, headers, config) do
    case Keyword.get(config, :secret) do
      nil -> :ok
      secret -> verify_signature(raw_body, header(headers, @header), secret, config)
    end
  end

  defp verify_signature(raw_body, signature, secret, config) when is_binary(signature) do
    tolerance = Keyword.get(config, :tolerance, @default_tolerance)

    with {:ok, timestamp, digest} <- split(signature),
         :ok <- check_timestamp(timestamp, tolerance) do
      expected =
        :hmac
        |> :crypto.mac(:sha256, secret, [Integer.to_string(timestamp), ".", raw_body])
        |> Base.encode16(case: :lower)

      if secure_compare(expected, digest),
        do: :ok,
        else: {:error, Mailixir.Webhook.invalid_signature(provider())}
    end
  end

  defp verify_signature(_raw_body, _signature, _secret, _config) do
    {:error, Mailixir.Webhook.invalid_signature(provider(), "missing Facteur-Signature header")}
  end

  defp split(signature) do
    parts =
      for part <- String.split(signature, ","),
          [key, value] <- [String.split(part, "=", parts: 2)],
          into: %{},
          do: {key, value}

    with %{"t" => t, "v1" => digest} <- parts,
         {timestamp, ""} <- Integer.parse(t) do
      {:ok, timestamp, digest}
    else
      _ -> {:error, Mailixir.Webhook.invalid_signature(provider(), "malformed signature header")}
    end
  end

  defp check_timestamp(timestamp, tolerance) do
    if abs(System.os_time(:second) - timestamp) <= tolerance,
      do: :ok,
      else: {:error, Mailixir.Webhook.invalid_signature(provider(), "timestamp outside tolerance")}
  end

  @impl true
  def parse(%{"type" => name, "data" => data} = body, _config) when is_map(data) do
    {type, bounce_type} = classify(name)

    {:ok,
     [
       event(provider(),
         type: type,
         bounce_type: bounce_type,
         message_id: body["message_id"],
         recipient: get_in(body, ["recipient", "email"]),
         timestamp: iso8601(body["occurred_at"]),
         reason: data["response"] || data["reason"],
         tags: List.wrap(body["tags"]),
         metadata: body["metadata"] || %{},
         raw: body
       )
     ]}
  end

  def parse(_decoded, _config),
    do: {:error, invalid(provider(), "expected type and data fields")}

  defp classify("accepted"), do: {:accepted, nil}
  defp classify("delivered"), do: {:delivered, nil}
  defp classify("deferred"), do: {:deferred, nil}
  defp classify("bounced"), do: {:bounced, :hard}
  defp classify("complained"), do: {:complained, nil}
  defp classify("unsubscribed"), do: {:unsubscribed, nil}
  # Facteur never attempted this recipient (suppressed) or gave up on it (failed).
  defp classify("suppressed"), do: {:rejected, nil}
  defp classify("failed"), do: {:rejected, nil}
  defp classify(_other), do: {:other, nil}
end
