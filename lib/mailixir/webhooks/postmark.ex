defmodule Mailixir.Webhooks.Postmark do
  @moduledoc """
  Parses [Postmark webhooks](https://postmarkapp.com/developer/webhooks/webhooks-overview)
  (one record per request).

  Verification: Postmark signs nothing; configure the webhook URL with basic
  auth credentials and pass `basic_auth: {user, password}` to have the
  `Authorization` header checked.
  """

  use Mailixir.Webhook, provider: :postmark

  @impl true
  def verify(_raw_body, _decoded, headers, config) do
    case Keyword.get(config, :basic_auth) do
      nil ->
        :ok

      {user, password} ->
        expected = "Basic " <> Base.encode64("#{user}:#{password}")

        if secure_compare(expected, header(headers, "authorization") || ""),
          do: :ok,
          else: {:error, Mailixir.Webhook.invalid_signature(provider(), "basic auth credentials do not match")}
    end
  end

  @impl true
  def parse(%{"RecordType" => record} = data, _config) do
    {type, bounce_type} = classify(record, data)

    {:ok,
     [
       event(provider(),
         type: type,
         bounce_type: bounce_type,
         message_id: data["MessageID"],
         recipient: data["Recipient"] || data["Email"],
         timestamp: iso8601(data["DeliveredAt"] || data["BouncedAt"] || data["ReceivedAt"] || data["ChangedAt"]),
         reason: data["Description"] || data["Details"],
         url: data["OriginalLink"],
         tags: List.wrap(data["Tag"]),
         metadata: data["Metadata"] || %{},
         raw: data
       )
     ]}
  end

  def parse(_decoded, _config), do: {:error, invalid(provider(), "expected a RecordType field")}

  @soft_bounces ~w(SoftBounce Transient DnsError SpamNotification DMARCPolicy ManuallyDeactivated)

  defp classify("Delivery", _), do: {:delivered, nil}
  defp classify("Bounce", %{"Type" => type}) when type in @soft_bounces, do: {:bounced, :soft}
  defp classify("Bounce", _), do: {:bounced, :hard}
  defp classify("SpamComplaint", _), do: {:complained, nil}
  defp classify("Open", _), do: {:opened, nil}
  defp classify("Click", _), do: {:clicked, nil}
  defp classify("SubscriptionChange", %{"SuppressSending" => true}), do: {:unsubscribed, nil}
  defp classify(_, _), do: {:other, nil}
end
