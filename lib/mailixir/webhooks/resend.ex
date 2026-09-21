defmodule Mailixir.Webhooks.Resend do
  @moduledoc """
  Parses [Resend webhooks](https://resend.com/docs/dashboard/webhooks/introduction)
  (one `email.*` event per request; one `Mailixir.Event` per recipient).

  Verification: pass `signing_secret:` (`whsec_…`). Resend delivers through
  Svix, so the `svix-id`, `svix-timestamp` and `svix-signature` headers are
  checked with HMAC-SHA256, and the timestamp must be within `:tolerance`
  seconds of now (default 300).
  """

  use Mailixir.Webhook, provider: :resend

  @default_tolerance 300

  @impl true
  def verify(raw_body, _decoded, headers, config) do
    case Keyword.get(config, :signing_secret) do
      nil -> :ok
      secret -> verify_svix(raw_body, headers, secret, Keyword.get(config, :tolerance, @default_tolerance))
    end
  end

  defp verify_svix(raw_body, headers, secret, tolerance) do
    with id when is_binary(id) <- header(headers, "svix-id") || :missing,
         timestamp when is_binary(timestamp) <- header(headers, "svix-timestamp") || :missing,
         signatures when is_binary(signatures) <- header(headers, "svix-signature") || :missing,
         :ok <- check_timestamp(timestamp, tolerance),
         {:ok, key} <- secret |> String.replace_prefix("whsec_", "") |> Base.decode64() do
      expected = :crypto.mac(:hmac, :sha256, key, "#{id}.#{timestamp}.#{raw_body}") |> Base.encode64()

      signatures
      |> String.split(" ")
      |> Enum.any?(fn
        "v1," <> signature -> secure_compare(expected, signature)
        _ -> false
      end)
      |> if(do: :ok, else: {:error, Mailixir.Webhook.invalid_signature(provider())})
    else
      :missing -> {:error, Mailixir.Webhook.invalid_signature(provider(), "missing svix headers")}
      :error -> {:error, Error.new(:invalid_config, "signing_secret is not valid base64", provider: provider())}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp check_timestamp(timestamp, tolerance) do
    with {seconds, ""} <- Integer.parse(timestamp),
         true <- abs(System.os_time(:second) - seconds) <= tolerance do
      :ok
    else
      _ -> {:error, Mailixir.Webhook.invalid_signature(provider(), "svix-timestamp outside tolerance")}
    end
  end

  @impl true
  def parse(%{"type" => name, "data" => %{} = data} = body, _config) do
    {type, bounce_type} = classify(name, get_in(data, ["bounce", "type"]))
    {tags, metadata} = split_tags(data["tags"])
    timestamp = iso8601(body["created_at"] || data["created_at"])

    events =
      for recipient <- List.wrap(data["to"]) do
        event(provider(),
          type: type,
          bounce_type: bounce_type,
          message_id: data["email_id"],
          recipient: recipient,
          timestamp: timestamp,
          reason: get_in(data, ["bounce", "message"]) || get_in(data, ["failed", "reason"]),
          url: get_in(data, ["click", "link"]),
          tags: tags,
          metadata: metadata,
          raw: body
        )
      end

    {:ok, events}
  end

  def parse(_decoded, _config), do: {:error, invalid(provider(), "expected type and data fields")}

  defp classify("email.sent", _), do: {:accepted, nil}
  defp classify("email.delivered", _), do: {:delivered, nil}
  defp classify("email.delivery_delayed", _), do: {:deferred, nil}
  defp classify("email.bounced", "Transient"), do: {:bounced, :soft}
  defp classify("email.bounced", _), do: {:bounced, :hard}
  defp classify("email.complained", _), do: {:complained, nil}
  defp classify("email.opened", _), do: {:opened, nil}
  defp classify("email.clicked", _), do: {:clicked, nil}
  defp classify("email.failed", _), do: {:rejected, nil}
  defp classify(_, _), do: {:other, nil}

  # Resend tags are name/value pairs; Mailixir.Adapters.Resend sends plain tags
  # as name "tag" and metadata as its own names, so undo that here.
  defp split_tags(tags) when is_map(tags),
    do: tags |> Enum.map(fn {k, v} -> %{"name" => k, "value" => v} end) |> split_tags()

  defp split_tags(tags) when is_list(tags) do
    {plain, meta} = Enum.split_with(tags, &(&1["name"] == "tag"))
    {Enum.map(plain, & &1["value"]), Map.new(meta, &{&1["name"], &1["value"]})}
  end

  defp split_tags(_), do: {[], %{}}
end
