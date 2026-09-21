defmodule Mailixir.Webhooks.MailtrapTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Error, Event, Webhook, Webhooks.Mailtrap}

  defp ev(name, extra \\ %{}),
    do:
      Map.merge(
        %{
          "event" => name,
          "message_id" => "mt-1",
          "email" => "jane@example.com",
          "timestamp" => 1_600_000_000,
          "category" => "welcome",
          "custom_variables" => %{"user_id" => "42"}
        },
        extra
      )

  test "events wrapper and bare array" do
    body =
      JSON.encode!(%{
        "events" => [
          ev("delivery", %{"response" => "250 OK"}),
          ev("bounce", %{"reason" => "user unknown"}),
          ev("soft_bounce"),
          ev("spam"),
          ev("open"),
          ev("click", %{"url" => "https://acme.com"}),
          ev("unsubscribe"),
          ev("reject"),
          ev("suspension"),
          ev("weird")
        ]
      })

    assert {:ok, events} = Webhook.parse(Mailtrap, body, [])

    assert [
             %Event{
               type: :delivered,
               message_id: "mt-1",
               recipient: "jane@example.com",
               tags: ["welcome"],
               metadata: %{"user_id" => "42"},
               reason: "250 OK"
             } = first,
             %Event{type: :bounced, bounce_type: :hard, reason: "user unknown"},
             %Event{type: :bounced, bounce_type: :soft},
             %Event{type: :complained},
             %Event{type: :opened},
             %Event{type: :clicked, url: "https://acme.com"},
             %Event{type: :unsubscribed},
             %Event{type: :rejected},
             %Event{type: :rejected},
             %Event{type: :other}
           ] = events

    assert first.timestamp == ~U[2020-09-13 12:26:40Z]
    assert {:ok, [%Event{type: :delivered}]} = Webhook.parse(Mailtrap, JSON.encode!([ev("delivery")]), [])
  end

  test "invalid payload" do
    assert {:error, %Error{reason: :invalid_payload}} = Webhook.parse(Mailtrap, "{}", [])
  end
end
