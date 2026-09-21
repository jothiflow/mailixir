defmodule Mailixir.Webhooks.SES do
  @moduledoc """
  Parses [Amazon SES event notifications](https://docs.aws.amazon.com/ses/latest/dg/event-publishing-retrieving-sns-contents.html)
  delivered through an SNS HTTPS subscription. Both the SNS envelope
  (`Type: Notification` with a JSON `Message` string) and a bare SES event
  object are accepted.

  An SNS `SubscriptionConfirmation` yields a single `:other` event whose
  `:raw` holds the envelope — fetch its `SubscribeURL` to confirm.

  Verification: SNS signs each envelope with a certificate you have to
  download from `SigningCertURL`; that belongs in an HTTP-aware layer, so
  this module does not verify. `Mailixir.Event.tags` come from the `tag`
  message tags `Mailixir.Adapters.SES` sends; other message tags become
  `metadata`.
  """

  use Mailixir.Webhook, provider: :ses

  @impl true
  def parse(%{"Type" => "SubscriptionConfirmation"} = envelope, _config) do
    {:ok, [event(provider(), type: :other, raw: envelope)]}
  end

  def parse(%{"Type" => "Notification", "Message" => message}, config) when is_binary(message) do
    with {:ok, decoded} <- Mailixir.Webhook.decode_json(message, provider()), do: parse(decoded, config)
  end

  def parse(%{"mail" => %{} = mail} = data, _config) do
    kind = data["eventType"] || data["notificationType"]
    {type, bounce_type, section, recipients_key} = classify(kind, data)
    section = data[section] || %{}
    {tags, metadata} = split_tags(mail["tags"])

    recipients =
      case section[recipients_key] do
        [_ | _] = list -> Enum.map(list, &recipient_address/1)
        _ -> List.wrap(mail["destination"])
      end

    events =
      for recipient <- recipients do
        event(provider(),
          type: type,
          bounce_type: bounce_type,
          message_id: mail["messageId"],
          recipient: recipient,
          timestamp: iso8601(section["timestamp"] || mail["timestamp"]),
          reason: reason(kind, section, recipient),
          url: section["link"],
          tags: tags,
          metadata: metadata,
          raw: data
        )
      end

    {:ok, events}
  end

  def parse(_decoded, _config), do: {:error, invalid(provider(), "expected an SES event with a mail object")}

  defp classify("Send", _), do: {:accepted, nil, "send", nil}
  defp classify("Delivery", _), do: {:delivered, nil, "delivery", "recipients"}
  defp classify("DeliveryDelay", _), do: {:deferred, nil, "deliveryDelay", "delayedRecipients"}

  defp classify("Bounce", %{"bounce" => %{"bounceType" => "Transient"}}),
    do: {:bounced, :soft, "bounce", "bouncedRecipients"}

  defp classify("Bounce", _), do: {:bounced, :hard, "bounce", "bouncedRecipients"}
  defp classify("Complaint", _), do: {:complained, nil, "complaint", "complainedRecipients"}
  defp classify("Reject", _), do: {:rejected, nil, "reject", nil}
  defp classify("RenderingFailure", _), do: {:rejected, nil, "failure", nil}
  defp classify("Open", _), do: {:opened, nil, "open", nil}
  defp classify("Click", _), do: {:clicked, nil, "click", nil}
  defp classify("Subscription", _), do: {:unsubscribed, nil, "subscription", nil}
  defp classify(_, _), do: {:other, nil, "unknown", nil}

  defp recipient_address(%{"emailAddress" => address}), do: address
  defp recipient_address(address) when is_binary(address), do: address

  defp reason("Bounce", %{"bouncedRecipients" => list}, recipient) do
    case Enum.find(list, &(&1["emailAddress"] == recipient)) do
      %{"diagnosticCode" => code} when is_binary(code) -> code
      _ -> nil
    end
  end

  defp reason("Complaint", section, _), do: section["complaintFeedbackType"]
  defp reason("Reject", section, _), do: section["reason"]
  defp reason("RenderingFailure", section, _), do: section["errorMessage"]
  defp reason("DeliveryDelay", section, _), do: section["delayType"]
  defp reason(_, _, _), do: nil

  # SES reports tags as %{name => [values]}.
  defp split_tags(tags) when is_map(tags) do
    {plain, meta} = Enum.split_with(tags, fn {name, _} -> name == "tag" end)

    {Enum.flat_map(plain, fn {_, values} -> List.wrap(values) end),
     Map.new(meta, fn {k, v} -> {k, v |> List.wrap() |> List.first()} end)}
  end

  defp split_tags(_), do: {[], %{}}
end
