defmodule Mailixir.Webhooks.PostalTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Error, Event, Webhook, Webhooks.Postal}

  defp body(name, payload \\ %{}) do
    message = %{
      "id" => 1,
      "token" => "abc",
      "message_id" => "<msg@postal>",
      "to" => "jane@example.com",
      "tag" => "welcome"
    }

    JSON.encode!(%{
      "event" => name,
      "timestamp" => 1_600_000_000.5,
      "uuid" => "u",
      "payload" => Map.merge(%{"message" => message}, payload)
    })
  end

  test "events" do
    assert {:ok,
            [%Event{type: :delivered, message_id: "msg@postal", recipient: "jane@example.com", tags: ["welcome"]} = e]} =
             Webhook.parse(Postal, body("MessageSent", %{"status" => "Sent", "details" => "Message accepted"}), [])

    assert e.timestamp == ~U[2020-09-13 12:26:40Z]
    assert e.reason == "Message accepted"

    assert {:ok, [%Event{type: :deferred}]} =
             Webhook.parse(Postal, body("MessageDelayed", %{"status" => "SoftFail"}), [])

    assert {:ok, [%Event{type: :bounced, bounce_type: :soft}]} =
             Webhook.parse(Postal, body("MessageDeliveryFailed", %{"status" => "SoftFail"}), [])

    assert {:ok, [%Event{type: :bounced, bounce_type: :hard, reason: "550"}]} =
             Webhook.parse(Postal, body("MessageDeliveryFailed", %{"status" => "HardFail", "output" => "550"}), [])

    assert {:ok, [%Event{type: :bounced, bounce_type: :hard}]} = Webhook.parse(Postal, body("MessageBounced"), [])
    assert {:ok, [%Event{type: :rejected}]} = Webhook.parse(Postal, body("MessageHeld"), [])
    assert {:ok, [%Event{type: :opened}]} = Webhook.parse(Postal, body("MessageLoaded"), [])

    assert {:ok, [%Event{type: :clicked, url: "https://acme.com"}]} =
             Webhook.parse(Postal, body("MessageLinkClicked", %{"url" => "https://acme.com"}), [])
  end

  test "rsa signature" do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} = private
    public = {:RSAPublicKey, modulus, exponent}
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public)])

    raw = body("MessageSent")
    signature = :public_key.sign(raw, :sha, private) |> Base.encode64()

    assert {:ok, _} = Webhook.parse(Postal, raw, [{"x-postal-signature", signature}], public_key: pem)

    assert {:error, %Error{reason: :invalid_signature}} =
             Webhook.parse(Postal, raw <> " ", [{"x-postal-signature", signature}], public_key: pem)

    assert {:error, %Error{reason: :invalid_signature, message: "missing X-Postal-Signature header"}} =
             Webhook.parse(Postal, raw, [], public_key: pem)

    assert {:error, %Error{reason: :invalid_config}} =
             Webhook.parse(Postal, raw, [{"x-postal-signature", signature}], public_key: "garbage")
  end

  test "invalid payload" do
    assert {:error, %Error{reason: :invalid_payload}} = Webhook.parse(Postal, "{}", [])
  end
end
