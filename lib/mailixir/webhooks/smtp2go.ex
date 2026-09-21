defmodule Mailixir.Webhooks.SMTP2GO do
  @moduledoc """
  Parses [SMTP2GO webhooks](https://support.smtp2go.com/hc/en-gb/articles/223087067-Webhooks)
  (one event per request, or an array).

  SMTP2GO offers no signature; it can add fixed custom headers to the request,
  so pass `auth_header: {"x-webhook-secret", "value"}` to require one.

  `message_id` is the `email_id`, matching `Mailixir.Adapters.SMTP2GO`.
  Field names vary slightly between SMTP2GO event types, so several
  candidate keys are read for recipient, reason and timestamp.
  """

  use Mailixir.Webhook, provider: :smtp2go

  @impl true
  def verify(_raw_body, _decoded, headers, config) do
    case Keyword.get(config, :auth_header) do
      nil ->
        :ok

      {name, value} ->
        if secure_compare(value, header(headers, name) || ""),
          do: :ok,
          else: {:error, Mailixir.Webhook.invalid_signature(provider(), "#{name} header does not match")}
    end
  end

  @impl true
  def parse(events, _config) when is_list(events), do: {:ok, Enum.map(events, &to_event/1)}
  def parse(%{"event" => _} = event, _config), do: {:ok, [to_event(event)]}
  def parse(_decoded, _config), do: {:error, invalid(provider(), "expected an event object or array")}

  defp to_event(%{"event" => name} = data) do
    {type, bounce_type} = classify(name, data["bounce_type"] || data["type"])

    event(provider(),
      type: type,
      bounce_type: bounce_type,
      message_id: data["email_id"],
      recipient: data["rcpt"] || data["recipient"] || data["email"],
      timestamp: timestamp(data["time"] || data["timestamp"]),
      reason: data["reason"] || data["bounce"] || data["message"],
      url: data["url"],
      raw: data
    )
  end

  defp to_event(data), do: event(provider(), type: :other, raw: data)

  defp classify("processed", _), do: {:accepted, nil}
  defp classify("delivered", _), do: {:delivered, nil}
  defp classify("bounce", kind) when kind in ["soft", "softbounce"], do: {:bounced, :soft}
  defp classify("bounce", _), do: {:bounced, :hard}
  defp classify("spam", _), do: {:complained, nil}
  defp classify("open", _), do: {:opened, nil}
  defp classify("click", _), do: {:clicked, nil}
  defp classify("unsubscribe", _), do: {:unsubscribed, nil}
  defp classify("reject", _), do: {:rejected, nil}
  defp classify(_, _), do: {:other, nil}

  defp timestamp(value) when is_binary(value), do: iso8601(value) || unix(value)
  defp timestamp(value), do: unix(value)
end
