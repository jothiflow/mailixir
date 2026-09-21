defmodule Mailixir.Webhooks.MailjetTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Error, Event, Webhook, Webhooks.Mailjet}

  defp event(name, extra \\ %{}) do
    Map.merge(
      %{
        "event" => name,
        "time" => 1_600_000_000,
        "MessageID" => 123,
        "Message_GUID" => "uuid-1",
        "email" => "jane@example.com",
        "Payload" => ~s({"user_id":"42"}),
        "customcampaign" => "spring"
      },
      extra
    )
  end

  test "array and single object" do
    assert {:ok,
            [
              %Event{
                type: :delivered,
                message_id: "uuid-1",
                recipient: "jane@example.com",
                metadata: %{"user_id" => "42"},
                tags: ["spring"]
              } = e,
              %Event{type: :opened}
            ]} =
             Webhook.parse(Mailjet, JSON.encode!([event("sent"), event("open")]), [])

    assert e.timestamp == ~U[2020-09-13 12:26:40Z]

    assert {:ok, [%Event{type: :clicked, url: "https://acme.com"}]} =
             Webhook.parse(Mailjet, JSON.encode!(event("click", %{"url" => "https://acme.com"})), [])
  end

  test "bounces, blocks and reasons" do
    assert {:ok, [%Event{type: :bounced, bounce_type: :hard, reason: "user unknown - recipient"}]} =
             Webhook.parse(
               Mailjet,
               JSON.encode!(
                 event("bounce", %{"hard_bounce" => true, "error" => "user unknown", "error_related_to" => "recipient"})
               ),
               []
             )

    assert {:ok, [%Event{type: :bounced, bounce_type: :soft}]} =
             Webhook.parse(Mailjet, JSON.encode!(event("bounce", %{"hard_bounce" => false})), [])

    assert {:ok, [%Event{type: :rejected, reason: "preblocked"}]} =
             Webhook.parse(Mailjet, JSON.encode!(event("blocked", %{"error" => "preblocked"})), [])

    assert {:ok, [%Event{type: :complained}]} = Webhook.parse(Mailjet, JSON.encode!(event("spam")), [])
    assert {:ok, [%Event{type: :unsubscribed}]} = Webhook.parse(Mailjet, JSON.encode!(event("unsub")), [])

    assert {:ok, [%Event{type: :other, metadata: %{"payload" => "plain"}}]} =
             Webhook.parse(Mailjet, JSON.encode!(event("weird", %{"Payload" => "plain"})), [])
  end

  test "invalid payload" do
    assert {:error, %Error{reason: :invalid_payload}} = Webhook.parse(Mailjet, "{}", [])
  end
end
