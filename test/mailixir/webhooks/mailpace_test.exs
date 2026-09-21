defmodule Mailixir.Webhooks.MailPaceTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Error, Event, Webhook, Webhooks.MailPace}

  defp body(name, extra \\ %{}) do
    JSON.encode!(%{
      "event" => name,
      "payload" =>
        Map.merge(
          %{
            "id" => 1234,
            "status" => "delivered",
            "to" => "jane@example.com, john@example.com",
            "from" => "a@x.com",
            "subject" => "Hi",
            "tags" => ["welcome"],
            "created_at" => "2024-01-01T10:00:00Z",
            "updated_at" => "2024-01-01T10:00:05Z"
          },
          extra
        )
    })
  end

  test "one event per recipient" do
    assert {:ok,
            [
              %Event{type: :delivered, message_id: "1234", recipient: "jane@example.com", tags: ["welcome"]} = first,
              %Event{recipient: "john@example.com"}
            ]} =
             Webhook.parse(MailPace, body("email.delivered"), [])

    assert first.timestamp == ~U[2024-01-01 10:00:05Z]
  end

  test "event types" do
    assert {:ok, [%Event{type: :accepted} | _]} = Webhook.parse(MailPace, body("email.queued"), [])
    assert {:ok, [%Event{type: :deferred} | _]} = Webhook.parse(MailPace, body("email.deferred"), [])

    assert {:ok, [%Event{type: :bounced, bounce_type: :hard} | _]} =
             Webhook.parse(MailPace, body("email.bounced", %{"status" => "hardbounced"}), [])

    assert {:ok, [%Event{type: :bounced, bounce_type: :soft} | _]} =
             Webhook.parse(MailPace, body("email.bounced", %{"status" => "softbounced"}), [])

    assert {:ok, [%Event{type: :complained} | _]} = Webhook.parse(MailPace, body("email.spam"), [])

    assert {:ok, [%Event{type: :other, recipient: nil}]} =
             Webhook.parse(MailPace, body("inbound.email", %{"to" => nil}), [])
  end

  test "ed25519 signature" do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    raw = body("email.delivered")
    signature = :crypto.sign(:eddsa, :none, raw, [private, :ed25519]) |> Base.encode64()
    key = Base.encode64(public)

    assert {:ok, _} = Webhook.parse(MailPace, raw, [{"x-mailpace-signature", signature}], public_key: key)

    assert {:error, %Error{reason: :invalid_signature}} =
             Webhook.parse(MailPace, raw <> " ", [{"x-mailpace-signature", signature}], public_key: key)

    assert {:error, %Error{reason: :invalid_signature, message: "missing X-MailPace-Signature header"}} =
             Webhook.parse(MailPace, raw, [], public_key: key)
  end

  test "invalid payload" do
    assert {:error, %Error{reason: :invalid_payload}} = Webhook.parse(MailPace, "{}", [])
  end
end
