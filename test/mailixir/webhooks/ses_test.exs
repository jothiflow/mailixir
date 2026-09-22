defmodule Mailixir.Webhooks.SESTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Error, Event, Webhook, Webhooks.SES}

  @mail %{
    "messageId" => "0100018-abc",
    "timestamp" => "2026-09-21T10:00:00.000Z",
    "destination" => ["jane@example.com", "john@example.com"],
    "tags" => %{"tag" => ["welcome", "v2"], "user_id" => ["42"], "ses:configuration-set" => ["default"]}
  }

  defp ses(kind, extra \\ %{}), do: Map.merge(%{"eventType" => kind, "mail" => @mail}, extra)

  defp sns(message),
    do: JSON.encode!(%{"Type" => "Notification", "MessageId" => "sns-1", "Message" => JSON.encode!(message)})

  test "SNS envelope with a delivery" do
    delivery = %{"delivery" => %{"timestamp" => "2026-09-21T10:00:05.000Z", "recipients" => ["jane@example.com"]}}

    assert {:ok, [%Event{type: :delivered, message_id: "0100018-abc", recipient: "jane@example.com"} = e]} =
             Webhook.parse(SES, sns(ses("Delivery", delivery)), [])

    assert e.timestamp == ~U[2026-09-21 10:00:05Z]
    assert e.tags == ["welcome", "v2"]
    assert e.metadata == %{"user_id" => "42", "ses:configuration-set" => "default"}
  end

  test "bare event, bounce per recipient with diagnostics" do
    bounce = %{
      "bounce" => %{
        "bounceType" => "Permanent",
        "bouncedRecipients" => [
          %{"emailAddress" => "jane@example.com", "diagnosticCode" => "smtp; 550 5.1.1 user unknown"},
          %{"emailAddress" => "john@example.com"}
        ]
      }
    }

    assert {:ok,
            [
              %Event{
                type: :bounced,
                bounce_type: :hard,
                recipient: "jane@example.com",
                reason: "smtp; 550 5.1.1 user unknown"
              },
              %Event{recipient: "john@example.com", reason: nil}
            ]} =
             Webhook.parse(SES, JSON.encode!(ses("Bounce", bounce)), [])

    transient = %{"bounce" => %{"bounceType" => "Transient", "bouncedRecipients" => [%{"emailAddress" => "a@x.com"}]}}

    assert {:ok, [%Event{type: :bounced, bounce_type: :soft}]} =
             Webhook.parse(SES, JSON.encode!(ses("Bounce", transient)), [])
  end

  test "other event types fall back to destination" do
    assert {:ok, [%Event{type: :accepted, recipient: "jane@example.com"}, %Event{recipient: "john@example.com"}]} =
             Webhook.parse(SES, JSON.encode!(ses("Send")), [])

    assert {:ok, [%Event{type: :complained, reason: "abuse"} | _]} =
             Webhook.parse(
               SES,
               JSON.encode!(
                 ses("Complaint", %{
                   "complaint" => %{
                     "complainedRecipients" => [%{"emailAddress" => "jane@example.com"}],
                     "complaintFeedbackType" => "abuse"
                   }
                 })
               ),
               []
             )

    assert {:ok, [%Event{type: :deferred, reason: "MailboxFull"}]} =
             Webhook.parse(
               SES,
               JSON.encode!(
                 ses("DeliveryDelay", %{
                   "deliveryDelay" => %{
                     "delayType" => "MailboxFull",
                     "delayedRecipients" => [%{"emailAddress" => "a@x.com"}]
                   }
                 })
               ),
               []
             )

    assert {:ok, [%Event{type: :rejected, reason: "Bad content"} | _]} =
             Webhook.parse(SES, JSON.encode!(ses("Reject", %{"reject" => %{"reason" => "Bad content"}})), [])

    assert {:ok, [%Event{type: :clicked, url: "https://acme.com"} | _]} =
             Webhook.parse(SES, JSON.encode!(ses("Click", %{"click" => %{"link" => "https://acme.com"}})), [])

    assert {:ok, [%Event{type: :opened} | _]} = Webhook.parse(SES, JSON.encode!(ses("Open")), [])

    assert {:ok, [%Event{type: :delivered} | _]} =
             Webhook.parse(SES, JSON.encode!(%{"notificationType" => "Delivery", "mail" => @mail}), [])
  end

  test "subscription confirmation and invalid payloads" do
    envelope = %{"Type" => "SubscriptionConfirmation", "SubscribeURL" => "https://sns/confirm"}

    assert {:ok, [%Event{type: :other, raw: %{"SubscribeURL" => "https://sns/confirm"}}]} =
             Webhook.parse(SES, JSON.encode!(envelope), [])

    assert {:error, %Error{reason: :invalid_payload}} = Webhook.parse(SES, "{}", [])

    assert {:error, %Error{reason: :invalid_payload}} =
             Webhook.parse(SES, JSON.encode!(%{"Type" => "Notification", "Message" => "not json"}), [])
  end

  describe "SNS signature verification" do
    @topic "arn:aws:sns:eu-west-1:123456789012:ses-events"

    setup do
      %{cert: der, key: key} = :public_key.pkix_test_root_cert(~c"SNS test", key: {:rsa, 2048, 65_537})
      pem = :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
      stub = :"sns_#{System.unique_integer([:positive])}"

      Req.Test.stub(stub, fn conn ->
        send(self(), :cert_fetched)
        Plug.Conn.send_resp(conn, 200, pem)
      end)

      # A fresh URL per test, so the per-URL certificate cache never crosses tests.
      cert_url =
        "https://sns.eu-west-1.amazonaws.com/SimpleNotificationService-#{stub}.pem"

      %{key: key, cert_url: cert_url, config: [topic_arn: @topic, req_options: [plug: {Req.Test, stub}]]}
    end

    defp signed(ctx, fields, version \\ "2") do
      envelope =
        Map.merge(
          %{
            "Type" => "Notification",
            "MessageId" => "sns-1",
            "TopicArn" => @topic,
            "Timestamp" => "2026-09-22T10:00:00.000Z",
            "SignatureVersion" => version,
            "SigningCertURL" => ctx.cert_url,
            "Message" => JSON.encode!(%{"eventType" => "Send", "mail" => @mail})
          },
          fields
        )

      keys =
        if envelope["Type"] == "Notification",
          do: ~w(Message MessageId Subject Timestamp TopicArn Type),
          else: ~w(Message MessageId SubscribeURL Timestamp Token TopicArn Type)

      string = for k <- keys, v = envelope[k], into: "", do: "#{k}\n#{v}\n"
      digest = if version == "1", do: :sha, else: :sha256
      signature = string |> :public_key.sign(digest, ctx.key) |> Base.encode64()

      Map.put(envelope, "Signature", signature)
    end

    test "accepts a correctly signed notification, and caches the certificate", ctx do
      body = JSON.encode!(signed(ctx, %{}))

      assert {:ok, [%Event{type: :accepted} | _]} = Webhook.parse(SES, body, [], ctx.config)
      assert_received :cert_fetched

      assert {:ok, _} = Webhook.parse(SES, body, [], ctx.config)
      refute_received :cert_fetched
    end

    test "accepts signature version 1 and a Subject", ctx do
      body = JSON.encode!(signed(ctx, %{"Subject" => "Amazon SES Email Event Notification"}, "1"))
      assert {:ok, [_ | _]} = Webhook.parse(SES, body, [], ctx.config)
    end

    test "accepts a signed subscription confirmation", ctx do
      envelope =
        signed(ctx, %{
          "Type" => "SubscriptionConfirmation",
          "Token" => "tok",
          "SubscribeURL" => "https://sns.eu-west-1.amazonaws.com/?Action=ConfirmSubscription",
          "Message" => "You have chosen to subscribe"
        })

      assert {:ok, [%Event{type: :other}]} = Webhook.parse(SES, JSON.encode!(envelope), [], ctx.config)
    end

    test "rejects a tampered message", ctx do
      envelope = signed(ctx, %{}) |> Map.put("Message", JSON.encode!(%{"eventType" => "Bounce", "mail" => @mail}))

      assert {:error, %Error{reason: :invalid_signature, message: "SNS signature does not match"}} =
               Webhook.parse(SES, JSON.encode!(envelope), [], ctx.config)
    end

    test "rejects a validly signed message from another topic", ctx do
      body = JSON.encode!(signed(ctx, %{"TopicArn" => "arn:aws:sns:eu-west-1:999999999999:attacker"}))

      assert {:error, %Error{reason: :invalid_signature, message: "unexpected SNS topic" <> _}} =
               Webhook.parse(SES, body, [], ctx.config)

      refute_received :cert_fetched
    end

    test "accepts any topic in a list", ctx do
      config = Keyword.put(ctx.config, :topic_arn, ["arn:aws:sns:us-east-1:1:other", @topic])
      assert {:ok, _} = Webhook.parse(SES, JSON.encode!(signed(ctx, %{})), [], config)
    end

    test "refuses certificates from anywhere but SNS", ctx do
      for url <- [
            "https://evil.example.com/cert.pem",
            "http://sns.eu-west-1.amazonaws.com/cert.pem",
            "https://sns.eu-west-1.amazonaws.com.evil.com/cert.pem",
            "https://sns.eu-west-1.amazonaws.com:8443/cert.pem",
            "https://sns.eu-west-1.amazonaws.com/cert.txt"
          ] do
        body = JSON.encode!(signed(%{ctx | cert_url: url}, %{}))

        assert {:error, %Error{reason: :invalid_signature, message: "SigningCertURL" <> _}} =
                 Webhook.parse(SES, body, [], ctx.config)
      end

      refute_received :cert_fetched
    end

    test "refuses a bare SES event and an unsigned envelope", ctx do
      assert {:error, %Error{reason: :invalid_signature}} =
               Webhook.parse(SES, JSON.encode!(ses("Send")), [], ctx.config)

      unsigned = signed(ctx, %{}) |> Map.delete("Signature")

      assert {:error, %Error{reason: :invalid_signature}} =
               Webhook.parse(SES, JSON.encode!(unsigned), [], ctx.config)
    end

    test "refuses an unknown signature version", ctx do
      body = signed(ctx, %{}) |> Map.put("SignatureVersion", "3") |> JSON.encode!()
      assert {:error, %Error{reason: :invalid_signature}} = Webhook.parse(SES, body, [], ctx.config)
    end

    test "a failed certificate fetch is a transport error, so SNS can retry", ctx do
      stub = :"sns_down_#{System.unique_integer([:positive])}"
      Req.Test.stub(stub, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
      config = Keyword.put(ctx.config, :req_options, plug: {Req.Test, stub})

      assert {:error, %Error{reason: :transport, status: 503}} =
               Webhook.parse(SES, JSON.encode!(signed(ctx, %{})), [], config)
    end

    test "without topic_arn nothing is verified", ctx do
      body = signed(ctx, %{}) |> Map.put("Signature", "garbage") |> JSON.encode!()
      assert {:ok, _} = Webhook.parse(SES, body, [])
    end
  end
end
