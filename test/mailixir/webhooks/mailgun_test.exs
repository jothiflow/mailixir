defmodule Mailixir.Webhooks.MailgunTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Error, Event, Webhook, Webhooks.Mailgun}

  @key "whk-secret"

  defp body(event, extra \\ %{}) do
    ts = "1529006854"
    token = "token-abc"
    signature = :crypto.mac(:hmac, :sha256, @key, ts <> token) |> Base.encode16(case: :lower)

    data =
      Map.merge(
        %{
          "event" => event,
          "recipient" => "jane@example.com",
          "timestamp" => 1_529_006_854.329574,
          "message" => %{"headers" => %{"message-id" => "20180614@mg.acme.com"}},
          "tags" => ["welcome"],
          "user-variables" => %{"user_id" => "42"}
        },
        extra
      )

    JSON.encode!(%{
      "signature" => %{"timestamp" => ts, "token" => token, "signature" => signature},
      "event-data" => data
    })
  end

  test "delivered event with verified signature" do
    assert {:ok, [%Event{} = event]} = Webhook.parse(Mailgun, body("delivered"), [], signing_key: @key)
    assert event.type == :delivered
    assert event.provider == :mailgun
    assert event.message_id == "20180614@mg.acme.com"
    assert event.recipient == "jane@example.com"
    assert event.timestamp == ~U[2018-06-14 20:07:34Z]
    assert event.tags == ["welcome"]
    assert event.metadata == %{"user_id" => "42"}
  end

  test "failures, rejections and engagement" do
    permanent = %{
      "severity" => "permanent",
      "delivery-status" => %{"message" => "550 5.1.1 no such user", "description" => ""}
    }

    assert {:ok, [%Event{type: :bounced, bounce_type: :hard, reason: "550 5.1.1 no such user"}]} =
             Webhook.parse(Mailgun, body("failed", permanent), [])

    temporary = %{"severity" => "temporary", "delivery-status" => %{"description" => "Mailbox full"}}

    assert {:ok, [%Event{type: :deferred, reason: "Mailbox full"}]} =
             Webhook.parse(Mailgun, body("failed", temporary), [])

    assert {:ok, [%Event{type: :rejected, reason: "suppressed"}]} =
             Webhook.parse(Mailgun, body("rejected", %{"reject" => %{"reason" => "suppressed"}}), [])

    assert {:ok, [%Event{type: :clicked, url: "https://acme.com"}]} =
             Webhook.parse(Mailgun, body("clicked", %{"url" => "https://acme.com"}), [])

    assert {:ok, [%Event{type: :opened}]} = Webhook.parse(Mailgun, body("opened"), [])
    assert {:ok, [%Event{type: :complained}]} = Webhook.parse(Mailgun, body("complained"), [])
    assert {:ok, [%Event{type: :unsubscribed}]} = Webhook.parse(Mailgun, body("unsubscribed"), [])
    assert {:ok, [%Event{type: :accepted}]} = Webhook.parse(Mailgun, body("accepted"), [])
    assert {:ok, [%Event{type: :other}]} = Webhook.parse(Mailgun, body("stored"), [])
  end

  test "bad signature and missing signature" do
    assert {:error, %Error{reason: :invalid_signature, provider: :mailgun}} =
             Webhook.parse(Mailgun, body("delivered"), [], signing_key: "wrong")

    unsigned = JSON.encode!(%{"event-data" => %{"event" => "delivered"}})

    assert {:error, %Error{reason: :invalid_signature, message: "body has no signature object"}} =
             Webhook.parse(Mailgun, unsigned, [], signing_key: @key)

    assert {:ok, [_]} = Webhook.parse(Mailgun, unsigned, [])
  end

  test "invalid payloads" do
    assert {:error, %Error{reason: :invalid_payload}} = Webhook.parse(Mailgun, "not json", [])

    assert {:error, %Error{reason: :invalid_payload, message: "expected an event-data object"}} =
             Webhook.parse(Mailgun, "{}", [])
  end
end
