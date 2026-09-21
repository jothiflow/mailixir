defmodule Mailixir.Webhooks.Brevo do
  @moduledoc """
  Parses [Brevo transactional webhooks](https://developers.brevo.com/docs/transactional-webhooks)
  (one event per request).

  Brevo offers no signature; protect the endpoint at the web layer.
  `metadata` is decoded from the `X-Mailin-custom` header that
  `Mailixir.Adapters.Brevo` sets from `Mailixir.Email` metadata.
  """

  use Mailixir.Webhook, provider: :brevo

  alias Mailixir.Response

  @impl true
  def parse(%{"event" => name} = data, _config) do
    {type, bounce_type} = classify(name)

    {:ok,
     [
       event(provider(),
         type: type,
         bounce_type: bounce_type,
         message_id: Response.normalize_id(data["message-id"]),
         recipient: data["email"],
         timestamp: timestamp(data),
         reason: data["reason"],
         url: data["link"],
         tags: List.wrap(data["tags"] || data["tag"]),
         metadata: metadata(data["X-Mailin-custom"]),
         raw: data
       )
     ]}
  end

  def parse(_decoded, _config), do: {:error, invalid(provider(), "expected an event field")}

  defp classify("request"), do: {:accepted, nil}
  defp classify("delivered"), do: {:delivered, nil}
  defp classify("deferred"), do: {:deferred, nil}
  defp classify("hard_bounce"), do: {:bounced, :hard}
  defp classify("soft_bounce"), do: {:bounced, :soft}
  defp classify("blocked"), do: {:rejected, nil}
  defp classify("invalid_email"), do: {:rejected, nil}
  defp classify("error"), do: {:rejected, nil}
  defp classify("spam"), do: {:complained, nil}
  defp classify("opened"), do: {:opened, nil}
  defp classify("unique_opened"), do: {:opened, nil}
  defp classify("click"), do: {:clicked, nil}
  defp classify("unsubscribed"), do: {:unsubscribed, nil}
  defp classify(_), do: {:other, nil}

  defp timestamp(%{"ts_epoch" => epoch}) when is_integer(epoch), do: unix(epoch)
  defp timestamp(%{"ts_event" => ts}) when is_integer(ts), do: unix(ts)
  defp timestamp(%{"date" => date}), do: iso8601(date)
  defp timestamp(_), do: nil

  defp metadata(custom) when is_binary(custom) and custom != "" do
    case JSON.decode(custom) do
      {:ok, %{} = map} -> map
      _ -> %{"X-Mailin-custom" => custom}
    end
  end

  defp metadata(_), do: %{}
end
