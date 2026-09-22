defmodule Mailixir.Webhooks.SES do
  @moduledoc """
  Parses [Amazon SES event notifications](https://docs.aws.amazon.com/ses/latest/dg/event-publishing-retrieving-sns-contents.html)
  delivered through an SNS HTTPS subscription. Both the SNS envelope
  (`Type: Notification` with a JSON `Message` string) and a bare SES event
  object are accepted.

  An SNS `SubscriptionConfirmation` yields a single `:other` event whose
  `:raw` holds the envelope — fetch its `SubscribeURL` to confirm.

  Verification: pass `topic_arn:` (one ARN or a list) to verify the SNS
  signature and accept only those topics. A valid signature proves only
  that SNS sent the message — anyone can create a topic and subscribe your
  URL to it — so the topic check is not optional, and verification never
  runs without it. The signing certificate is fetched over HTTPS from
  `SigningCertURL` (which must be an `sns.<region>.amazonaws.com` `.pem`),
  honours `:req_options`, and is cached per URL. Signature versions 1
  (SHA1) and 2 (SHA256) are accepted. With verification on, a bare SES
  event outside an SNS envelope is refused. A failed certificate fetch is a
  `:transport` error: answer 5xx so SNS retries.

  `Mailixir.Event.tags` come from the `tag` message tags
  `Mailixir.Adapters.SES` sends; other message tags become `metadata`.
  """

  use Mailixir.Webhook, provider: :ses

  alias Mailixir.Adapter.HTTP

  require Record

  Record.defrecordp(
    :otp_certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :otp_tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :otp_subject_public_key_info,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/public_key.hrl")
  )

  @notification_fields ~w(Message MessageId Subject Timestamp TopicArn Type)
  @confirmation_fields ~w(Message MessageId SubscribeURL Timestamp Token TopicArn Type)
  @cert_host ~r/\Asns\.[a-z0-9-]+\.amazonaws\.com(\.cn)?\z/

  @impl true
  def verify(_raw_body, decoded, _headers, config) do
    case Keyword.get(config, :topic_arn) do
      nil -> :ok
      topic_arns -> verify_sns(decoded, List.wrap(topic_arns), config)
    end
  end

  defp verify_sns(%{"Type" => type, "TopicArn" => topic_arn} = envelope, topic_arns, config) do
    with :ok <- check_topic(topic_arn, topic_arns),
         {:ok, fields} <- signed_fields(type),
         {:ok, digest} <- digest(envelope["SignatureVersion"]),
         {:ok, signature} <- decode_signature(envelope["Signature"]),
         {:ok, key} <- signing_key(envelope["SigningCertURL"], config) do
      if :public_key.verify(string_to_sign(envelope, fields), digest, signature, key),
        do: :ok,
        else: {:error, rejected("SNS signature does not match")}
    end
  end

  defp verify_sns(_decoded, _topic_arns, _config),
    do: {:error, rejected("expected a signed SNS envelope with a TopicArn")}

  defp check_topic(topic_arn, topic_arns) do
    if topic_arn in topic_arns, do: :ok, else: {:error, rejected("unexpected SNS topic #{topic_arn}")}
  end

  defp signed_fields("Notification"), do: {:ok, @notification_fields}
  defp signed_fields("SubscriptionConfirmation"), do: {:ok, @confirmation_fields}
  defp signed_fields("UnsubscribeConfirmation"), do: {:ok, @confirmation_fields}
  defp signed_fields(type), do: {:error, rejected("unknown SNS message type #{inspect(type)}")}

  defp digest("1"), do: {:ok, :sha}
  defp digest("2"), do: {:ok, :sha256}
  defp digest(version), do: {:error, rejected("unsupported SNS SignatureVersion #{inspect(version)}")}

  defp decode_signature(signature) when is_binary(signature) do
    case Base.decode64(signature) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, rejected("SNS signature is not base64")}
    end
  end

  defp decode_signature(_), do: {:error, rejected("SNS envelope has no Signature")}

  # Absent keys (Subject on a notification sent without one) are left out
  # rather than signed as empty.
  defp string_to_sign(envelope, fields) do
    for field <- fields, value = envelope[field], is_binary(value), into: "" do
      field <> "\n" <> value <> "\n"
    end
  end

  defp signing_key(url, config) do
    with :ok <- check_cert_url(url) do
      case :persistent_term.get({__MODULE__, url}, nil) do
        nil -> fetch_signing_key(url, config)
        key -> {:ok, key}
      end
    end
  end

  defp check_cert_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme == "https" and uri.port == 443 and is_nil(uri.userinfo) and
         is_binary(uri.host) and Regex.match?(@cert_host, uri.host) and
         String.ends_with?(uri.path || "", ".pem"),
       do: :ok,
       else: {:error, rejected("SigningCertURL is not an Amazon SNS certificate: #{url}")}
  end

  defp check_cert_url(_), do: {:error, rejected("SNS envelope has no SigningCertURL")}

  defp fetch_signing_key(url, config) do
    request = [method: :get, url: url, decode_body: false, retry: false]

    case HTTP.request(provider(), config, request) do
      {:ok, %Req.Response{status: 200, body: pem}} when is_binary(pem) ->
        with {:ok, key} <- public_key(pem) do
          :persistent_term.put({__MODULE__, url}, key)
          {:ok, key}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error,
         Error.new(:transport, "fetching the SNS signing certificate returned HTTP #{status}",
           provider: provider(),
           status: status
         )}

      {:error, _transport} = error ->
        error
    end
  end

  defp public_key(pem) do
    with [{:Certificate, der, _} | _] <- :public_key.pem_decode(pem),
         otp_certificate(tbsCertificate: tbs) <- :public_key.pkix_decode_cert(der, :otp),
         otp_tbs_certificate(subjectPublicKeyInfo: info) <- tbs,
         otp_subject_public_key_info(subjectPublicKey: {:RSAPublicKey, _, _} = key) <- info do
      {:ok, key}
    else
      _ -> {:error, rejected("SigningCertURL did not return an RSA certificate")}
    end
  rescue
    _ -> {:error, rejected("SigningCertURL did not return a certificate")}
  end

  defp rejected(message), do: Mailixir.Webhook.invalid_signature(provider(), message)

  @impl true
  def parse(%{"Type" => "SubscriptionConfirmation"} = envelope, _config) do
    {:ok, [event(provider(), type: :other, raw: envelope)]}
  end

  def parse(%{"Type" => "Notification", "Message" => message}, config) when is_binary(message) do
    with {:ok, decoded} <- Mailixir.Webhook.decode_json(message, provider()), do: parse(decoded, config)
  end

  def parse(%{"mail" => %{} = mail} = data, _config) do
    kind = data["eventType"] || data["notificationType"]
    {type, bounce_type, section, recipients_key} = classify(kind, data)
    section = data[section] || %{}
    {tags, metadata} = split_tags(mail["tags"])

    recipients =
      case section[recipients_key] do
        [_ | _] = list -> Enum.map(list, &recipient_address/1)
        _ -> List.wrap(mail["destination"])
      end

    events =
      for recipient <- recipients do
        event(provider(),
          type: type,
          bounce_type: bounce_type,
          message_id: mail["messageId"],
          recipient: recipient,
          timestamp: iso8601(section["timestamp"] || mail["timestamp"]),
          reason: reason(kind, section, recipient),
          url: section["link"],
          tags: tags,
          metadata: metadata,
          raw: data
        )
      end

    {:ok, events}
  end

  def parse(_decoded, _config), do: {:error, invalid(provider(), "expected an SES event with a mail object")}

  defp classify("Send", _), do: {:accepted, nil, "send", nil}
  defp classify("Delivery", _), do: {:delivered, nil, "delivery", "recipients"}
  defp classify("DeliveryDelay", _), do: {:deferred, nil, "deliveryDelay", "delayedRecipients"}

  defp classify("Bounce", %{"bounce" => %{"bounceType" => "Transient"}}),
    do: {:bounced, :soft, "bounce", "bouncedRecipients"}

  defp classify("Bounce", _), do: {:bounced, :hard, "bounce", "bouncedRecipients"}
  defp classify("Complaint", _), do: {:complained, nil, "complaint", "complainedRecipients"}
  defp classify("Reject", _), do: {:rejected, nil, "reject", nil}
  defp classify("RenderingFailure", _), do: {:rejected, nil, "failure", nil}
  defp classify("Open", _), do: {:opened, nil, "open", nil}
  defp classify("Click", _), do: {:clicked, nil, "click", nil}
  defp classify("Subscription", _), do: {:unsubscribed, nil, "subscription", nil}
  defp classify(_, _), do: {:other, nil, "unknown", nil}

  defp recipient_address(%{"emailAddress" => address}), do: address
  defp recipient_address(address) when is_binary(address), do: address

  defp reason("Bounce", %{"bouncedRecipients" => list}, recipient) do
    case Enum.find(list, &(&1["emailAddress"] == recipient)) do
      %{"diagnosticCode" => code} when is_binary(code) -> code
      _ -> nil
    end
  end

  defp reason("Complaint", section, _), do: section["complaintFeedbackType"]
  defp reason("Reject", section, _), do: section["reason"]
  defp reason("RenderingFailure", section, _), do: section["errorMessage"]
  defp reason("DeliveryDelay", section, _), do: section["delayType"]
  defp reason(_, _, _), do: nil

  # SES reports tags as %{name => [values]}.
  defp split_tags(tags) when is_map(tags) do
    {plain, meta} = Enum.split_with(tags, fn {name, _} -> name == "tag" end)

    {Enum.flat_map(plain, fn {_, values} -> List.wrap(values) end),
     Map.new(meta, fn {k, v} -> {k, v |> List.wrap() |> List.first()} end)}
  end

  defp split_tags(_), do: {[], %{}}
end
