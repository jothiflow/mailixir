defmodule Mailixir.Webhooks.Mailgun do
  @moduledoc """
  Parses [Mailgun webhooks](https://documentation.mailgun.com/docs/mailgun/user-manual/tracking-messages/)
  (one event per request).

  Verification: pass `signing_key:` (the HTTP webhook signing key from the
  Mailgun dashboard); the `signature` object inside the body is checked with
  HMAC-SHA256.
  """

  use Mailixir.Webhook, provider: :mailgun

  alias Mailixir.Response

  @impl true
  def verify(_raw_body, decoded, _headers, config) do
    case {Keyword.get(config, :signing_key), decoded} do
      {nil, _} ->
        :ok

      {key, %{"signature" => %{"timestamp" => ts, "token" => token, "signature" => signature}}} ->
        expected = :crypto.mac(:hmac, :sha256, key, "#{ts}#{token}") |> Base.encode16(case: :lower)
        if secure_compare(expected, signature), do: :ok, else: {:error, Mailixir.Webhook.invalid_signature(provider())}

      {_key, _} ->
        {:error, Mailixir.Webhook.invalid_signature(provider(), "body has no signature object")}
    end
  end

  @impl true
  def parse(%{"event-data" => %{"event" => name} = data}, _config) do
    {type, bounce_type} = classify(name, data["severity"])

    {:ok,
     [
       event(provider(),
         type: type,
         bounce_type: bounce_type,
         message_id: Response.normalize_id(get_in(data, ["message", "headers", "message-id"])),
         recipient: data["recipient"],
         timestamp: unix(data["timestamp"]),
         reason: reason(data),
         url: data["url"],
         tags: List.wrap(data["tags"]),
         metadata: data["user-variables"] || %{},
         raw: data
       )
     ]}
  end

  def parse(_decoded, _config), do: {:error, invalid(provider(), "expected an event-data object")}

  defp classify("accepted", _), do: {:accepted, nil}
  defp classify("delivered", _), do: {:delivered, nil}
  defp classify("failed", "temporary"), do: {:deferred, nil}
  defp classify("failed", _), do: {:bounced, :hard}
  defp classify("rejected", _), do: {:rejected, nil}
  defp classify("opened", _), do: {:opened, nil}
  defp classify("clicked", _), do: {:clicked, nil}
  defp classify("unsubscribed", _), do: {:unsubscribed, nil}
  defp classify("complained", _), do: {:complained, nil}
  defp classify(_, _), do: {:other, nil}

  defp reason(%{"delivery-status" => %{} = status}) do
    status["description"] |> blank_to_nil() || status["message"] |> blank_to_nil() || reason(%{})
  end

  defp reason(%{"reject" => %{"reason" => reason}}), do: reason
  defp reason(%{"reason" => reason}) when is_binary(reason), do: reason
  defp reason(_), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
