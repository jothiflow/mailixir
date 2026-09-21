defmodule Mailixir.Webhooks.PostmarkTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Error, Event, Webhook, Webhooks.Postmark}

  defp body(record, extra \\ %{}) do
    JSON.encode!(
      Map.merge(
        %{
          "RecordType" => record,
          "MessageID" => "pm-1",
          "Recipient" => "jane@example.com",
          "Tag" => "welcome",
          "Metadata" => %{"user_id" => "42"}
        },
        extra
      )
    )
  end

  test "records" do
    assert {:ok,
            [
              %Event{
                type: :delivered,
                message_id: "pm-1",
                recipient: "jane@example.com",
                tags: ["welcome"],
                metadata: %{"user_id" => "42"}
              } = e
            ]} =
             Webhook.parse(Postmark, body("Delivery", %{"DeliveredAt" => "2026-09-21T10:00:00Z"}), [])

    assert e.timestamp == ~U[2026-09-21 10:00:00Z]

    assert {:ok, [%Event{type: :bounced, bounce_type: :hard, reason: "The server was unable to deliver"}]} =
             Webhook.parse(
               Postmark,
               body("Bounce", %{
                 "Type" => "HardBounce",
                 "Email" => "jane@example.com",
                 "Description" => "The server was unable to deliver"
               }),
               []
             )

    assert {:ok, [%Event{type: :bounced, bounce_type: :soft}]} =
             Webhook.parse(Postmark, body("Bounce", %{"Type" => "Transient"}), [])

    assert {:ok, [%Event{type: :complained}]} = Webhook.parse(Postmark, body("SpamComplaint"), [])
    assert {:ok, [%Event{type: :opened}]} = Webhook.parse(Postmark, body("Open"), [])

    assert {:ok, [%Event{type: :clicked, url: "https://acme.com"}]} =
             Webhook.parse(Postmark, body("Click", %{"OriginalLink" => "https://acme.com"}), [])

    assert {:ok, [%Event{type: :unsubscribed}]} =
             Webhook.parse(Postmark, body("SubscriptionChange", %{"SuppressSending" => true}), [])

    assert {:ok, [%Event{type: :other}]} =
             Webhook.parse(Postmark, body("SubscriptionChange", %{"SuppressSending" => false}), [])
  end

  test "basic auth" do
    headers = [{"authorization", "Basic " <> Base.encode64("hook:s3cret")}]
    assert {:ok, _} = Webhook.parse(Postmark, body("Delivery"), headers, basic_auth: {"hook", "s3cret"})

    assert {:error, %Error{reason: :invalid_signature}} =
             Webhook.parse(Postmark, body("Delivery"), headers, basic_auth: {"hook", "wrong"})

    assert {:error, %Error{reason: :invalid_signature}} =
             Webhook.parse(Postmark, body("Delivery"), [], basic_auth: {"hook", "s3cret"})
  end

  test "invalid payload" do
    assert {:error, %Error{reason: :invalid_payload}} = Webhook.parse(Postmark, "[]", [])
  end
end
