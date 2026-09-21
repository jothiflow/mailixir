defmodule Mailixir.Webhooks.SMTP2GOTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Error, Event, Webhook, Webhooks.SMTP2GO}

  defp ev(name, extra \\ %{}),
    do:
      Map.merge(
        %{"event" => name, "email_id" => "1a2b", "rcpt" => "jane@example.com", "time" => "2026-09-21T10:00:00Z"},
        extra
      )

  test "single event and array" do
    assert {:ok, [%Event{type: :delivered, message_id: "1a2b", recipient: "jane@example.com"} = first]} =
             Webhook.parse(SMTP2GO, JSON.encode!(ev("delivered")), [])

    assert first.timestamp == ~U[2026-09-21 10:00:00Z]

    body =
      JSON.encode!([
        ev("processed"),
        ev("bounce", %{"bounce_type" => "soft", "reason" => "full"}),
        ev("bounce", %{"bounce_type" => "hard"}),
        ev("spam"),
        ev("open"),
        ev("click", %{"url" => "https://acme.com"}),
        ev("unsubscribe"),
        ev("reject"),
        ev("x", %{"time" => 1_600_000_000})
      ])

    assert {:ok, events} = Webhook.parse(SMTP2GO, body, [])

    assert [
             %Event{type: :accepted},
             %Event{type: :bounced, bounce_type: :soft, reason: "full"},
             %Event{type: :bounced, bounce_type: :hard},
             %Event{type: :complained},
             %Event{type: :opened},
             %Event{type: :clicked, url: "https://acme.com"},
             %Event{type: :unsubscribed},
             %Event{type: :rejected},
             %Event{type: :other, timestamp: ~U[2020-09-13 12:26:40Z]}
           ] = events
  end

  test "auth header" do
    body = JSON.encode!(ev("delivered"))
    assert {:ok, _} = Webhook.parse(SMTP2GO, body, [{"X-Webhook-Secret", "s"}], auth_header: {"x-webhook-secret", "s"})

    assert {:error, %Error{reason: :invalid_signature}} =
             Webhook.parse(SMTP2GO, body, [], auth_header: {"x-webhook-secret", "s"})
  end

  test "invalid payload" do
    assert {:error, %Error{reason: :invalid_payload}} = Webhook.parse(SMTP2GO, "{}", [])
  end
end
