defmodule Mailixir.Webhooks.SESTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Error, Event, Webhook, Webhooks.SES}

  @mail %{
    "messageId" => "0100018-abc",
    "timestamp" => "2026-09-21T10:00:00.000Z",
    "destination" => ["jane@example.com", "john@example.com"],
    "tags" => %{"tag" => ["welcome", "v2"], "user_id" => ["42"], "ses:configuration-set" => ["default"]}
  }

  defp ses(kind, extra \\ %{}), do: Map.merge(%{"eventType" => kind, "mail" => @mail}, extra)

  defp sns(message),
    do: JSON.encode!(%{"Type" => "Notification", "MessageId" => "sns-1", "Message" => JSON.encode!(message)})

  test "SNS envelope with a delivery" do
    delivery = %{"delivery" => %{"timestamp" => "2026-09-21T10:00:05.000Z", "recipients" => ["jane@example.com"]}}

    assert {:ok, [%Event{type: :delivered, message_id: "0100018-abc", recipient: "jane@example.com"} = e]} =
             Webhook.parse(SES, sns(ses("Delivery", delivery)), [])

    assert e.timestamp == ~U[2026-09-21 10:00:05Z]
    assert e.tags == ["welcome", "v2"]
    assert e.metadata == %{"user_id" => "42", "ses:configuration-set" => "default"}
  end

  test "bare event, bounce per recipient with diagnostics" do
    bounce = %{
      "bounce" => %{
        "bounceType" => "Permanent",
        "bouncedRecipients" => [
          %{"emailAddress" => "jane@example.com", "diagnosticCode" => "smtp; 550 5.1.1 user unknown"},
          %{"emailAddress" => "john@example.com"}
        ]
      }
    }

    assert {:ok,
            [
              %Event{
                type: :bounced,
                bounce_type: :hard,
                recipient: "jane@example.com",
                reason: "smtp; 550 5.1.1 user unknown"
              },
              %Event{recipient: "john@example.com", reason: nil}
            ]} =
             Webhook.parse(SES, JSON.encode!(ses("Bounce", bounce)), [])

    transient = %{"bounce" => %{"bounceType" => "Transient", "bouncedRecipients" => [%{"emailAddress" => "a@x.com"}]}}

    assert {:ok, [%Event{type: :bounced, bounce_type: :soft}]} =
             Webhook.parse(SES, JSON.encode!(ses("Bounce", transient)), [])
  end

  test "other event types fall back to destination" do
    assert {:ok, [%Event{type: :accepted, recipient: "jane@example.com"}, %Event{recipient: "john@example.com"}]} =
             Webhook.parse(SES, JSON.encode!(ses("Send")), [])

    assert {:ok, [%Event{type: :complained, reason: "abuse"} | _]} =
             Webhook.parse(
               SES,
               JSON.encode!(
                 ses("Complaint", %{
                   "complaint" => %{
                     "complainedRecipients" => [%{"emailAddress" => "jane@example.com"}],
                     "complaintFeedbackType" => "abuse"
                   }
                 })
               ),
               []
             )

    assert {:ok, [%Event{type: :deferred, reason: "MailboxFull"}]} =
             Webhook.parse(
               SES,
               JSON.encode!(
                 ses("DeliveryDelay", %{
                   "deliveryDelay" => %{
                     "delayType" => "MailboxFull",
                     "delayedRecipients" => [%{"emailAddress" => "a@x.com"}]
                   }
                 })
               ),
               []
             )

    assert {:ok, [%Event{type: :rejected, reason: "Bad content"} | _]} =
             Webhook.parse(SES, JSON.encode!(ses("Reject", %{"reject" => %{"reason" => "Bad content"}})), [])

    assert {:ok, [%Event{type: :clicked, url: "https://acme.com"} | _]} =
             Webhook.parse(SES, JSON.encode!(ses("Click", %{"click" => %{"link" => "https://acme.com"}})), [])

    assert {:ok, [%Event{type: :opened} | _]} = Webhook.parse(SES, JSON.encode!(ses("Open")), [])

    assert {:ok, [%Event{type: :delivered} | _]} =
             Webhook.parse(SES, JSON.encode!(%{"notificationType" => "Delivery", "mail" => @mail}), [])
  end

  test "subscription confirmation and invalid payloads" do
    envelope = %{"Type" => "SubscriptionConfirmation", "SubscribeURL" => "https://sns/confirm"}

    assert {:ok, [%Event{type: :other, raw: %{"SubscribeURL" => "https://sns/confirm"}}]} =
             Webhook.parse(SES, JSON.encode!(envelope), [])

    assert {:error, %Error{reason: :invalid_payload}} = Webhook.parse(SES, "{}", [])

    assert {:error, %Error{reason: :invalid_payload}} =
             Webhook.parse(SES, JSON.encode!(%{"Type" => "Notification", "Message" => "not json"}), [])
  end
end
