defmodule Mailixir.Webhooks.Mailjet do
  @moduledoc """
  Parses [Mailjet event webhooks](https://dev.mailjet.com/email/guides/webhooks/)
  (a single event or, with grouping enabled, an array).

  Mailjet offers no signature; restrict the endpoint by URL secrecy or basic
  auth at the web layer. `message_id` is the `Message_GUID`, matching the
  `MessageUUID` returned at send time; `metadata` is the decoded `Payload`
  set from `Mailixir.Email` metadata.
  """

  use Mailixir.Webhook, provider: :mailjet

  @impl true
  def parse(events, config) when is_list(events), do: {:ok, Enum.map(events, &to_event(&1, config))}
  def parse(%{"event" => _} = event, config), do: {:ok, [to_event(event, config)]}
  def parse(_decoded, _config), do: {:error, invalid(provider(), "expected an event object or array")}

  defp to_event(%{"event" => name} = data, _config) do
    {type, bounce_type} = classify(name, data)

    event(provider(),
      type: type,
      bounce_type: bounce_type,
      message_id: data["Message_GUID"],
      recipient: data["email"],
      timestamp: unix(data["time"]),
      reason: reason(data),
      url: data["url"],
      tags: List.wrap(data["customcampaign"]),
      metadata: metadata(data["Payload"]),
      raw: data
    )
  end

  defp to_event(data, _config), do: event(provider(), type: :other, raw: data)

  defp classify("sent", _), do: {:delivered, nil}
  defp classify("open", _), do: {:opened, nil}
  defp classify("click", _), do: {:clicked, nil}
  defp classify("bounce", %{"hard_bounce" => true}), do: {:bounced, :hard}
  defp classify("bounce", _), do: {:bounced, :soft}
  defp classify("blocked", _), do: {:rejected, nil}
  defp classify("spam", _), do: {:complained, nil}
  defp classify("unsub", _), do: {:unsubscribed, nil}
  defp classify(_, _), do: {:other, nil}

  defp reason(data) do
    [data["error"], data["comment"], data["error_related_to"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " - ")
    end
  end

  defp metadata(payload) when is_binary(payload) and payload != "" do
    case JSON.decode(payload) do
      {:ok, %{} = map} -> map
      _ -> %{"payload" => payload}
    end
  end

  defp metadata(_), do: %{}
end
