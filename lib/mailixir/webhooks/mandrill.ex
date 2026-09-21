defmodule Mailixir.Webhooks.Mandrill do
  @moduledoc """
  Parses [Mailchimp Transactional (Mandrill) webhooks](https://mailchimp.com/developer/transactional/guides/track-respond-activity-webhooks/).

  Mandrill posts a form-encoded body whose `mandrill_events` field holds a
  JSON array; this module decodes that form itself, so pass the raw body.

  Verification: pass `webhook_key:` (shown next to the webhook in Mandrill)
  and `url:` (the exact webhook URL as configured there). The
  `X-Mandrill-Signature` header is checked with HMAC-SHA1 over the URL and
  the sorted form fields.
  """

  use Mailixir.Webhook, provider: :mandrill

  @impl true
  def decode(raw_body, _headers) do
    params = URI.decode_query(raw_body)

    case params do
      %{"mandrill_events" => json} ->
        with {:ok, events} <- Mailixir.Webhook.decode_json(json, provider()), do: {:ok, {params, events}}

      _ ->
        {:error, invalid(provider(), "body has no mandrill_events field")}
    end
  end

  @impl true
  def verify(_raw_body, {params, _events}, headers, config) do
    case {Keyword.get(config, :webhook_key), Keyword.get(config, :url)} do
      {nil, _} ->
        :ok

      {_key, nil} ->
        {:error,
         Error.new(:invalid_config, "Mandrill verification needs :url as well as :webhook_key", provider: provider())}

      {key, url} ->
        signed = params |> Enum.sort() |> Enum.map_join(fn {k, v} -> k <> v end)
        expected = :crypto.mac(:hmac, :sha, key, url <> signed) |> Base.encode64()

        if secure_compare(expected, header(headers, "x-mandrill-signature") || ""),
          do: :ok,
          else: {:error, Mailixir.Webhook.invalid_signature(provider())}
    end
  end

  @impl true
  def parse({_params, events}, _config) when is_list(events), do: {:ok, Enum.map(events, &to_event/1)}
  def parse(_decoded, _config), do: {:error, invalid(provider(), "expected a mandrill_events array")}

  defp to_event(%{"event" => name} = data) do
    msg = data["msg"] || %{}
    {type, bounce_type} = classify(name)

    event(provider(),
      type: type,
      bounce_type: bounce_type,
      message_id: msg["_id"] || data["_id"],
      recipient: msg["email"],
      timestamp: unix(data["ts"]),
      reason: msg["bounce_description"] || msg["diag"] || msg["reject"],
      url: data["url"],
      tags: List.wrap(msg["tags"]),
      metadata: msg["metadata"] || %{},
      raw: data
    )
  end

  defp to_event(data), do: event(provider(), type: :other, raw: data)

  defp classify("send"), do: {:delivered, nil}
  defp classify("deferral"), do: {:deferred, nil}
  defp classify("hard_bounce"), do: {:bounced, :hard}
  defp classify("soft_bounce"), do: {:bounced, :soft}
  defp classify("open"), do: {:opened, nil}
  defp classify("click"), do: {:clicked, nil}
  defp classify("spam"), do: {:complained, nil}
  defp classify("unsub"), do: {:unsubscribed, nil}
  defp classify("reject"), do: {:rejected, nil}
  defp classify(_), do: {:other, nil}
end
