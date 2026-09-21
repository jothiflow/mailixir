defmodule Mailixir.Webhooks.SendGridTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Error, Event, Webhook, Webhooks.SendGrid}

  @events [
    %{
      "email" => "jane@example.com",
      "timestamp" => 1_600_000_000,
      "event" => "delivered",
      "sg_message_id" => "abc123.filterdrecv-p3mdw1-1.recv",
      "smtp-id" => "<x@y>",
      "response" => "250 OK",
      "category" => ["welcome", "v2"],
      "user_id" => "42"
    },
    %{
      "email" => "a@x.com",
      "timestamp" => 1_600_000_001,
      "event" => "bounce",
      "type" => "bounce",
      "reason" => "550 no such user",
      "sg_message_id" => "def"
    },
    %{
      "email" => "a@x.com",
      "timestamp" => 1_600_000_002,
      "event" => "bounce",
      "type" => "blocked",
      "reason" => "IP blocked"
    },
    %{
      "email" => "a@x.com",
      "timestamp" => 1_600_000_003,
      "event" => "click",
      "url" => "https://acme.com",
      "category" => "one"
    },
    %{"email" => "a@x.com", "event" => "dropped", "reason" => "Bounced Address"},
    %{"email" => "a@x.com", "event" => "group_unsubscribe"},
    %{"email" => "a@x.com", "event" => "processed"},
    %{"email" => "a@x.com", "event" => "spamreport"},
    %{"email" => "a@x.com", "event" => "deferred", "response" => "421 try later"}
  ]

  test "parses an event batch" do
    assert {:ok, events} = Webhook.parse(SendGrid, JSON.encode!(@events), [])

    assert [
             %Event{
               type: :delivered,
               message_id: "abc123",
               recipient: "jane@example.com",
               tags: ["welcome", "v2"],
               reason: "250 OK"
             } = first,
             %Event{type: :bounced, bounce_type: :hard, reason: "550 no such user", message_id: "def"},
             %Event{type: :bounced, bounce_type: :soft, reason: "IP blocked"},
             %Event{type: :clicked, url: "https://acme.com", tags: ["one"]},
             %Event{type: :rejected, reason: "Bounced Address"},
             %Event{type: :unsubscribed},
             %Event{type: :accepted},
             %Event{type: :complained},
             %Event{type: :deferred, reason: "421 try later"}
           ] = events

    assert first.timestamp == ~U[2020-09-13 12:26:40Z]
    assert first.metadata == %{"user_id" => "42"}
  end

  describe "signature verification" do
    setup do
      private = :public_key.generate_key({:namedCurve, :secp256r1})
      {:ECPrivateKey, _, _, _, point, _} = private
      public = {{:ECPoint, point}, {:namedCurve, :pubkey_cert_records.namedCurves(:secp256r1)}}
      {:SubjectPublicKeyInfo, der, :not_encrypted} = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public)
      {:ok, private: private, public_b64: Base.encode64(der)}
    end

    test "valid and invalid", %{private: private, public_b64: key} do
      body = JSON.encode!(@events)
      timestamp = "1600000000"
      signature = :public_key.sign(timestamp <> body, :sha256, private) |> Base.encode64()

      headers = [
        {"X-Twilio-Email-Event-Webhook-Signature", signature},
        {"X-Twilio-Email-Event-Webhook-Timestamp", timestamp}
      ]

      assert {:ok, [_ | _]} = Webhook.parse(SendGrid, body, headers, public_key: key)

      assert {:ok, [_ | _]} =
               Webhook.parse(SendGrid, body, headers,
                 public_key: "-----BEGIN PUBLIC KEY-----\n#{key}\n-----END PUBLIC KEY-----"
               )

      assert {:error, %Error{reason: :invalid_signature}} =
               Webhook.parse(SendGrid, body <> " ", headers, public_key: key)

      assert {:error, %Error{reason: :invalid_signature, message: "missing signature headers"}} =
               Webhook.parse(SendGrid, body, [], public_key: key)

      assert {:error, %Error{reason: :invalid_config}} = Webhook.parse(SendGrid, body, headers, public_key: "garbage")
    end
  end

  test "invalid payload" do
    assert {:error, %Error{reason: :invalid_payload}} = Webhook.parse(SendGrid, "{}", [])
  end
end
