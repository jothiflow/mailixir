defmodule Mailixir.Webhooks.SparkPostTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Error, Event, Webhook, Webhooks.SparkPost}

  defp msys(kind, data),
    do: %{
      "msys" => %{
        kind =>
          Map.merge(
            %{
              "transmission_id" => "tx-1",
              "rcpt_to" => "jane@example.com",
              "timestamp" => "1454442600",
              "campaign_id" => "spring",
              "rcpt_tags" => ["vip"],
              "rcpt_meta" => %{"user_id" => "42"}
            },
            data
          )
      }
    }

  test "batch of message, track and unsubscribe events" do
    body =
      JSON.encode!([
        msys("message_event", %{"type" => "delivery"}),
        msys("message_event", %{"type" => "bounce", "bounce_class" => "10", "reason" => "550 user unknown"}),
        msys("message_event", %{"type" => "bounce", "bounce_class" => 22, "raw_reason" => "mailbox full"}),
        msys("message_event", %{"type" => "delay"}),
        msys("message_event", %{"type" => "policy_rejection", "reason" => "suppressed"}),
        msys("message_event", %{"type" => "spam_complaint"}),
        msys("message_event", %{"type" => "injection"}),
        msys("track_event", %{"type" => "click", "target_link_url" => "https://acme.com"}),
        msys("track_event", %{"type" => "initial_open"}),
        msys("unsubscribe_event", %{"type" => "list_unsubscribe"}),
        %{"msys" => %{}}
      ])

    assert {:ok, events} = Webhook.parse(SparkPost, body, [])

    assert [
             %Event{
               type: :delivered,
               message_id: "tx-1",
               recipient: "jane@example.com",
               tags: ["spring", "vip"],
               metadata: %{"user_id" => "42"}
             } = first,
             %Event{type: :bounced, bounce_type: :hard, reason: "550 user unknown"},
             %Event{type: :bounced, bounce_type: :soft, reason: "mailbox full"},
             %Event{type: :deferred},
             %Event{type: :rejected, reason: "suppressed"},
             %Event{type: :complained},
             %Event{type: :accepted},
             %Event{type: :clicked, url: "https://acme.com"},
             %Event{type: :opened},
             %Event{type: :unsubscribed}
           ] = events

    assert first.timestamp == ~U[2016-02-02 19:50:00Z]
  end

  test "auth token and basic auth" do
    body = JSON.encode!([msys("message_event", %{"type" => "delivery"})])
    assert {:ok, _} = Webhook.parse(SparkPost, body, [{"authorization", "tok"}], auth_token: "tok")

    assert {:error, %Error{reason: :invalid_signature}} =
             Webhook.parse(SparkPost, body, [{"authorization", "nope"}], auth_token: "tok")

    assert {:ok, _} =
             Webhook.parse(SparkPost, body, [{"authorization", "Basic " <> Base.encode64("u:p")}],
               basic_auth: {"u", "p"}
             )

    assert {:error, %Error{reason: :invalid_signature}} = Webhook.parse(SparkPost, body, [], basic_auth: {"u", "p"})
  end

  test "invalid payload" do
    assert {:error, %Error{reason: :invalid_payload}} = Webhook.parse(SparkPost, "{}", [])
  end
end
