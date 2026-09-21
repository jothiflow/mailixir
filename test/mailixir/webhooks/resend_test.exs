defmodule Mailixir.Webhooks.ResendTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Error, Event, Webhook, Webhooks.Resend}

  @secret_raw :crypto.strong_rand_bytes(24)
  @secret "whsec_" <> Base.encode64(@secret_raw)

  defp body(type, data \\ %{}) do
    JSON.encode!(%{
      "type" => type,
      "created_at" => "2024-02-22T23:41:12.126Z",
      "data" =>
        Map.merge(
          %{
            "email_id" => "56761188-7520-42d8-8898-ff6fc54ce618",
            "from" => "Acme <onboarding@resend.dev>",
            "to" => ["jane@example.com", "john@example.com"],
            "subject" => "Hello",
            "tags" => [%{"name" => "tag", "value" => "welcome"}, %{"name" => "user_id", "value" => "42"}]
          },
          data
        )
    })
  end

  defp signed_headers(body, timestamp \\ System.os_time(:second)) do
    id = "msg_123"
    signature = :crypto.mac(:hmac, :sha256, @secret_raw, "#{id}.#{timestamp}.#{body}") |> Base.encode64()
    [{"svix-id", id}, {"svix-timestamp", "#{timestamp}"}, {"svix-signature", "v1,#{signature} v1,other"}]
  end

  test "one event per recipient with tags split back out" do
    body = body("email.delivered")
    assert {:ok, [first, second]} = Webhook.parse(Resend, body, signed_headers(body), signing_secret: @secret)

    assert %Event{
             type: :delivered,
             provider: :resend,
             recipient: "jane@example.com",
             message_id: "56761188-7520-42d8-8898-ff6fc54ce618"
           } = first

    assert first.timestamp == ~U[2024-02-22 23:41:12Z]
    assert first.tags == ["welcome"]
    assert first.metadata == %{"user_id" => "42"}
    assert second.recipient == "john@example.com"
  end

  test "event types" do
    assert {:ok, [%Event{type: :accepted} | _]} = Webhook.parse(Resend, body("email.sent"), [])
    assert {:ok, [%Event{type: :deferred} | _]} = Webhook.parse(Resend, body("email.delivery_delayed"), [])
    assert {:ok, [%Event{type: :complained} | _]} = Webhook.parse(Resend, body("email.complained"), [])
    assert {:ok, [%Event{type: :opened} | _]} = Webhook.parse(Resend, body("email.opened"), [])

    assert {:ok, [%Event{type: :bounced, bounce_type: :hard, reason: "no such user"} | _]} =
             Webhook.parse(
               Resend,
               body("email.bounced", %{"bounce" => %{"type" => "Permanent", "message" => "no such user"}}),
               []
             )

    assert {:ok, [%Event{type: :bounced, bounce_type: :soft} | _]} =
             Webhook.parse(Resend, body("email.bounced", %{"bounce" => %{"type" => "Transient"}}), [])

    assert {:ok, [%Event{type: :clicked, url: "https://acme.com"} | _]} =
             Webhook.parse(Resend, body("email.clicked", %{"click" => %{"link" => "https://acme.com"}}), [])

    assert {:ok, [%Event{type: :rejected, reason: "suppressed"} | _]} =
             Webhook.parse(Resend, body("email.failed", %{"failed" => %{"reason" => "suppressed"}}), [])

    assert {:ok, [%Event{type: :other, tags: []} | _]} =
             Webhook.parse(Resend, body("contact.created", %{"tags" => %{"category" => "x"}}), [])
  end

  test "signature failures" do
    body = body("email.sent")
    config = [signing_secret: @secret]

    assert {:error, %Error{reason: :invalid_signature}} =
             Webhook.parse(Resend, body <> " ", signed_headers(body), config)

    assert {:error, %Error{reason: :invalid_signature, message: "missing svix headers"}} =
             Webhook.parse(Resend, body, [], config)

    stale = System.os_time(:second) - 1000

    assert {:error, %Error{reason: :invalid_signature, message: "svix-timestamp outside tolerance"}} =
             Webhook.parse(Resend, body, signed_headers(body, stale), config)

    assert {:ok, _} = Webhook.parse(Resend, body, signed_headers(body, stale), signing_secret: @secret, tolerance: 2000)

    assert {:error, %Error{reason: :invalid_config}} =
             Webhook.parse(Resend, body, signed_headers(body), signing_secret: "whsec_%%%")
  end

  test "invalid payload" do
    assert {:error, %Error{reason: :invalid_payload}} = Webhook.parse(Resend, ~s({"foo": 1}), [])
  end
end
