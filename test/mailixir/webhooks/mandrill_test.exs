defmodule Mailixir.Webhooks.MandrillTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Error, Event, Webhook, Webhooks.Mandrill}

  @url "https://acme.com/webhooks/mandrill"
  @key "webhook-key"

  defp events do
    [
      %{
        "event" => "send",
        "ts" => 1_600_000_000,
        "msg" => %{
          "_id" => "abc",
          "email" => "jane@example.com",
          "tags" => ["welcome"],
          "metadata" => %{"user_id" => "42"}
        }
      },
      %{
        "event" => "hard_bounce",
        "ts" => 1_600_000_001,
        "msg" => %{"_id" => "def", "email" => "a@x.com", "bounce_description" => "bad_mailbox", "diag" => "550"}
      },
      %{
        "event" => "soft_bounce",
        "ts" => 1_600_000_002,
        "msg" => %{"_id" => "ghi", "email" => "a@x.com", "diag" => "452 full"}
      },
      %{
        "event" => "click",
        "ts" => 1_600_000_003,
        "url" => "https://acme.com",
        "msg" => %{"_id" => "jkl", "email" => "a@x.com"}
      },
      %{
        "event" => "reject",
        "ts" => 1_600_000_004,
        "msg" => %{"_id" => "mno", "email" => "a@x.com", "reject" => "spam"}
      },
      %{"event" => "deferral", "msg" => %{}},
      %{"event" => "open", "msg" => %{}},
      %{"event" => "spam", "msg" => %{}},
      %{"event" => "unsub", "msg" => %{}}
    ]
  end

  defp form(params), do: URI.encode_query(params)

  defp signature(params) do
    signed = params |> Enum.sort() |> Enum.map_join(fn {k, v} -> k <> v end)
    :crypto.mac(:hmac, :sha, @key, @url <> signed) |> Base.encode64()
  end

  test "decodes the form and parses events" do
    params = %{"mandrill_events" => JSON.encode!(events())}
    assert {:ok, parsed} = Webhook.parse(Mandrill, form(params), [])

    assert [
             %Event{
               type: :delivered,
               message_id: "abc",
               recipient: "jane@example.com",
               tags: ["welcome"],
               metadata: %{"user_id" => "42"}
             } = first,
             %Event{type: :bounced, bounce_type: :hard, reason: "bad_mailbox"},
             %Event{type: :bounced, bounce_type: :soft, reason: "452 full"},
             %Event{type: :clicked, url: "https://acme.com"},
             %Event{type: :rejected, reason: "spam"},
             %Event{type: :deferred},
             %Event{type: :opened},
             %Event{type: :complained},
             %Event{type: :unsubscribed}
           ] = parsed

    assert first.timestamp == ~U[2020-09-13 12:26:40Z]
  end

  test "signature verification" do
    params = %{"mandrill_events" => JSON.encode!(events()), "extra" => "1"}
    headers = [{"x-mandrill-signature", signature(params)}]
    config = [webhook_key: @key, url: @url]

    assert {:ok, _} = Webhook.parse(Mandrill, form(params), headers, config)

    assert {:error, %Error{reason: :invalid_signature}} =
             Webhook.parse(Mandrill, form(params), headers, Keyword.put(config, :url, @url <> "/"))

    assert {:error, %Error{reason: :invalid_signature}} = Webhook.parse(Mandrill, form(params), [], config)
    assert {:error, %Error{reason: :invalid_config}} = Webhook.parse(Mandrill, form(params), headers, webhook_key: @key)
  end

  test "invalid payloads" do
    assert {:error, %Error{reason: :invalid_payload, message: "body has no mandrill_events field"}} =
             Webhook.parse(Mandrill, "foo=bar", [])

    assert {:error, %Error{reason: :invalid_payload}} = Webhook.parse(Mandrill, "mandrill_events=nope", [])
  end
end
