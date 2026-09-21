defmodule Mailixir.Webhooks.Mailtrap do
  @moduledoc """
  Parses [Mailtrap webhooks](https://help.mailtrap.io/article/87-email-sending-webhooks)
  (`{"events": [...]}` batches).

  Mailtrap offers no signature; protect the endpoint at the web layer.
  `message_id` matches the ids returned by `Mailixir.Adapters.Mailtrap`;
  `category` becomes `tags` and `custom_variables` becomes `metadata`.
  """

  use Mailixir.Webhook, provider: :mailtrap

  @impl true
  def parse(%{"events" => events}, _config) when is_list(events), do: {:ok, Enum.map(events, &to_event/1)}
  def parse(events, _config) when is_list(events), do: {:ok, Enum.map(events, &to_event/1)}
  def parse(_decoded, _config), do: {:error, invalid(provider(), "expected an events array")}

  defp to_event(%{"event" => name} = data) do
    {type, bounce_type} = classify(name)

    event(provider(),
      type: type,
      bounce_type: bounce_type,
      message_id: data["message_id"],
      recipient: data["email"],
      timestamp: unix(data["timestamp"]),
      reason: data["reason"] || data["response"] || data["bounce_category"],
      url: data["url"],
      tags: List.wrap(data["category"]),
      metadata: data["custom_variables"] || %{},
      raw: data
    )
  end

  defp to_event(data), do: event(provider(), type: :other, raw: data)

  defp classify("delivery"), do: {:delivered, nil}
  defp classify("soft_bounce"), do: {:bounced, :soft}
  defp classify("bounce"), do: {:bounced, :hard}
  defp classify("spam"), do: {:complained, nil}
  defp classify("open"), do: {:opened, nil}
  defp classify("click"), do: {:clicked, nil}
  defp classify("unsubscribe"), do: {:unsubscribed, nil}
  defp classify(name) when name in ["reject", "suspension"], do: {:rejected, nil}
  defp classify(_), do: {:other, nil}
end
