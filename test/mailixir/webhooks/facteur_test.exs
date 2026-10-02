defmodule Mailixir.Webhooks.FacteurTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Error, Event, Webhook, Webhooks.Facteur}

  @secret "whsec_test"

  defp body(type, data \\ %{}) do
    JSON.encode!(%{
      "id" => "evt_1",
      "type" => type,
      "occurred_at" => "2026-09-21T10:00:05.123456Z",
      "message_id" => "6f0d",
      "delivery_id" => "d1",
      "recipient" => %{"email" => "jane@example.com", "name" => "Jane"},
      "tags" => ["welcome", "v2"],
      "metadata" => %{"user_id" => "42"},
      "data" => data
    })
  end

  defp signed(raw_body, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, System.os_time(:second))
    secret = Keyword.get(opts, :secret, @secret)

    digest =
      :hmac
      |> :crypto.mac(:sha256, secret, "#{timestamp}.#{raw_body}")
      |> Base.encode16(case: :lower)

    [{"facteur-signature", "t=#{timestamp},v1=#{digest}"}]
  end

  test "events" do
    raw = body("bounced", %{"response" => "550 5.1.1 User unknown", "code" => 550})

    assert {:ok, [%Event{} = e]} = Webhook.parse(Facteur, raw, signed(raw), secret: @secret)
    assert e.type == :bounced
    assert e.bounce_type == :hard
    assert e.provider == :facteur
    assert e.message_id == "6f0d"
    assert e.recipient == "jane@example.com"
    # Every parser normalises timestamps to second precision.
    assert e.timestamp == ~U[2026-09-21 10:00:05Z]
    assert e.reason == "550 5.1.1 User unknown"
    assert e.tags == ["welcome", "v2"]
    assert e.metadata == %{"user_id" => "42"}
    assert e.raw["id"] == "evt_1"
  end

  test "every type maps onto a Mailixir event" do
    for {facteur, expected} <- [
          {"accepted", :accepted},
          {"delivered", :delivered},
          {"deferred", :deferred},
          {"bounced", :bounced},
          {"complained", :complained},
          {"unsubscribed", :unsubscribed},
          {"opened", :opened},
          {"clicked", :clicked},
          {"suppressed", :rejected},
          {"failed", :rejected},
          {"something_new", :other}
        ] do
      raw = body(facteur)
      assert {:ok, [%Event{type: ^expected}]} = Webhook.parse(Facteur, raw, signed(raw), secret: @secret)
    end
  end

  test "a click carries its destination, an open has none" do
    clicked = body("clicked", %{"url" => "https://example.org/offer?a=1", "user_agent" => "Mail/1"})

    assert {:ok, [%Event{type: :clicked, url: "https://example.org/offer?a=1"} = e]} =
             Webhook.parse(Facteur, clicked, signed(clicked), secret: @secret)

    assert e.recipient == "jane@example.com"
    assert e.raw["data"]["user_agent"] == "Mail/1"

    opened = body("opened", %{"user_agent" => "Mail/1"})

    assert {:ok, [%Event{type: :opened, url: nil}]} =
             Webhook.parse(Facteur, opened, signed(opened), secret: @secret)
  end

  test "reason falls back to data.reason" do
    raw = body("failed", %{"reason" => "retry window of 72h exhausted"})

    assert {:ok, [%Event{reason: "retry window of 72h exhausted"}]} =
             Webhook.parse(Facteur, raw, signed(raw), secret: @secret)
  end

  test "a test send has no recipient or message" do
    raw =
      JSON.encode!(%{
        "id" => "evt_test",
        "type" => "delivered",
        "occurred_at" => "2026-09-21T10:00:00Z",
        "message_id" => nil,
        "delivery_id" => nil,
        "recipient" => nil,
        "tags" => [],
        "metadata" => %{},
        "data" => %{"test" => true}
      })

    assert {:ok, [%Event{type: :delivered, recipient: nil, message_id: nil, tags: []}]} =
             Webhook.parse(Facteur, raw, signed(raw), secret: @secret)
  end

  test "signature verification" do
    raw = body("delivered")

    assert {:error, %Error{reason: :invalid_signature}} =
             Webhook.parse(Facteur, raw, signed(raw, secret: "wrong"), secret: @secret)

    assert {:error, %Error{reason: :invalid_signature, message: message}} =
             Webhook.parse(Facteur, raw, [], secret: @secret)

    assert message =~ "missing Facteur-Signature header"

    assert {:error, %Error{reason: :invalid_signature, message: stale}} =
             Webhook.parse(
               Facteur,
               raw,
               signed(raw, timestamp: System.os_time(:second) - 3600),
               secret: @secret
             )

    assert stale =~ "timestamp outside tolerance"

    assert {:error, %Error{reason: :invalid_signature, message: malformed}} =
             Webhook.parse(Facteur, raw, [{"facteur-signature", "nonsense"}], secret: @secret)

    assert malformed =~ "malformed signature header"

    # A body altered after signing no longer verifies.
    headers = signed(raw)

    assert {:error, %Error{reason: :invalid_signature}} =
             Webhook.parse(Facteur, body("bounced"), headers, secret: @secret)
  end

  test "an old timestamp is accepted within an explicit tolerance" do
    raw = body("delivered")
    headers = signed(raw, timestamp: System.os_time(:second) - 3600)

    assert {:ok, [%Event{type: :delivered}]} =
             Webhook.parse(Facteur, raw, headers, secret: @secret, tolerance: 7200)
  end

  test "without a secret the signature is not checked" do
    raw = body("delivered")
    assert {:ok, [%Event{type: :delivered}]} = Webhook.parse(Facteur, raw, [])
  end

  test "an unexpected body is an invalid payload" do
    assert {:error, %Error{reason: :invalid_payload}} =
             Webhook.parse(Facteur, JSON.encode!(%{"foo" => 1}), [])

    assert {:error, %Error{reason: :invalid_payload}} = Webhook.parse(Facteur, "not json", [])
  end
end
