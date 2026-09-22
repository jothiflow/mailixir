defmodule Mailixir.Webhooks.BrevoTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Error, Event, Webhook, Webhooks.Brevo}

  defp body(name, extra \\ %{}) do
    JSON.encode!(
      Map.merge(
        %{
          "event" => name,
          "email" => "jane@example.com",
          "message-id" => "<1@smtp-relay.mailin.fr>",
          "date" => "2020-10-09 00:00:00",
          "tags" => ["welcome"],
          "X-Mailin-custom" => ~s({"user_id":"42"})
        },
        extra
      )
    )
  end

  test "events" do
    assert {:ok,
            [
              %Event{
                type: :delivered,
                message_id: "1@smtp-relay.mailin.fr",
                recipient: "jane@example.com",
                tags: ["welcome"],
                metadata: %{"user_id" => "42"}
              } = e
            ]} =
             Webhook.parse(Brevo, body("delivered"), [])

    assert e.timestamp == ~U[2020-10-09 00:00:00Z]

    assert {:ok, [%Event{type: :bounced, bounce_type: :hard, reason: "user unknown"} = hb]} =
             Webhook.parse(
               Brevo,
               body("hard_bounce", %{"reason" => "user unknown", "ts_epoch" => 1_600_000_000_000}),
               []
             )

    assert hb.timestamp == ~U[2020-09-13 12:26:40Z]
    assert {:ok, [%Event{type: :bounced, bounce_type: :soft}]} = Webhook.parse(Brevo, body("soft_bounce"), [])
    assert {:ok, [%Event{type: :deferred}]} = Webhook.parse(Brevo, body("deferred"), [])
    assert {:ok, [%Event{type: :rejected}]} = Webhook.parse(Brevo, body("blocked"), [])
    assert {:ok, [%Event{type: :rejected}]} = Webhook.parse(Brevo, body("invalid_email"), [])
    assert {:ok, [%Event{type: :complained}]} = Webhook.parse(Brevo, body("spam"), [])
    assert {:ok, [%Event{type: :opened}]} = Webhook.parse(Brevo, body("unique_opened"), [])

    assert {:ok, [%Event{type: :clicked, url: "https://acme.com"}]} =
             Webhook.parse(Brevo, body("click", %{"link" => "https://acme.com"}), [])

    assert {:ok, [%Event{type: :unsubscribed}]} = Webhook.parse(Brevo, body("unsubscribed"), [])

    assert {:ok, [%Event{type: :accepted, metadata: %{"X-Mailin-custom" => "raw"}}]} =
             Webhook.parse(Brevo, body("request", %{"X-Mailin-custom" => "raw"}), [])
  end

  test "invalid payload" do
    assert {:error, %Error{reason: :invalid_payload}} = Webhook.parse(Brevo, "{}", [])
  end

  describe "authentication" do
    test "basic auth, as Brevo sends credentials embedded in the URL" do
      config = [basic_auth: {"brevo", "s3cret"}]
      good = [{"authorization", "Basic " <> Base.encode64("brevo:s3cret")}]
      bad = [{"authorization", "Basic " <> Base.encode64("brevo:wrong")}]

      assert {:ok, [_]} = Webhook.parse(Brevo, body("delivered"), good, config)
      assert {:error, %Error{reason: :invalid_signature}} = Webhook.parse(Brevo, body("delivered"), bad, config)
      assert {:error, %Error{reason: :invalid_signature}} = Webhook.parse(Brevo, body("delivered"), [], config)
    end

    test "bearer token" do
      config = [bearer_token: "tok_123"]

      assert {:ok, [_]} =
               Webhook.parse(Brevo, body("delivered"), [{"Authorization", "Bearer tok_123"}], config)

      assert {:error, %Error{reason: :invalid_signature, message: "bearer token does not match"}} =
               Webhook.parse(Brevo, body("delivered"), [{"authorization", "Bearer nope"}], config)

      assert {:error, %Error{reason: :invalid_signature}} = Webhook.parse(Brevo, body("delivered"), [], config)
    end

    test "nothing is checked without a configured credential" do
      assert {:ok, [_]} = Webhook.parse(Brevo, body("delivered"), [])
    end
  end
end
