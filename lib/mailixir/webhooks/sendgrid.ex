defmodule Mailixir.Webhooks.SendGrid do
  @moduledoc """
  Parses the [SendGrid Event Webhook](https://www.twilio.com/docs/sendgrid/for-developers/tracking-events/event)
  (a JSON array of events per request).

  Verification: pass `public_key:` — the verification key shown in the
  SendGrid dashboard (base64 DER, or a PEM). The
  `X-Twilio-Email-Event-Webhook-Signature` / `-Timestamp` headers are checked
  with ECDSA P-256 / SHA-256.

  `message_id` is the part of `sg_message_id` before the first dot, which is
  the `X-Message-Id` value returned at send time.
  """

  use Mailixir.Webhook, provider: :sendgrid

  @known_keys ~w(email timestamp event sg_event_id sg_message_id smtp-id useragent ip url reason status response
    attempt category type tls cert_err url_offset asm_group_id sg_machine_open bounce_classification sg_content_type
    marketing_campaign_id marketing_campaign_name marketing_campaign_version marketing_campaign_split_id
    sg_template_id sg_template_name pool newsletter send_at)

  @impl true
  def verify(raw_body, _decoded, headers, config) do
    case Keyword.get(config, :public_key) do
      nil -> :ok
      key -> verify_signature(raw_body, headers, key)
    end
  end

  defp verify_signature(raw_body, headers, key) do
    signature = header(headers, "x-twilio-email-event-webhook-signature")
    timestamp = header(headers, "x-twilio-email-event-webhook-timestamp")

    with {:ok, public_key} <- decode_public_key(key),
         {:ok, signature} <- decode_signature(signature, timestamp),
         true <- :public_key.verify(timestamp <> raw_body, :sha256, signature, public_key) do
      :ok
    else
      false -> {:error, Mailixir.Webhook.invalid_signature(provider())}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp decode_signature(signature, timestamp) when is_binary(signature) and is_binary(timestamp) do
    case Base.decode64(signature) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, Mailixir.Webhook.invalid_signature(provider(), "signature is not valid base64")}
    end
  end

  defp decode_signature(_, _), do: {:error, Mailixir.Webhook.invalid_signature(provider(), "missing signature headers")}

  defp decode_public_key(key) do
    pem =
      if String.contains?(key, "-----BEGIN"),
        do: key,
        else: "-----BEGIN PUBLIC KEY-----\n#{key}\n-----END PUBLIC KEY-----"

    case :public_key.pem_decode(pem) do
      [entry] ->
        {:ok, :public_key.pem_entry_decode(entry)}

      _ ->
        {:error,
         Error.new(:invalid_config, "public_key is not a valid PEM or base64 DER public key", provider: provider())}
    end
  rescue
    _ -> {:error, Error.new(:invalid_config, "public_key could not be decoded", provider: provider())}
  end

  @impl true
  def parse(events, _config) when is_list(events), do: {:ok, Enum.map(events, &to_event/1)}
  def parse(_decoded, _config), do: {:error, invalid(provider(), "expected a JSON array of events")}

  defp to_event(%{"event" => name} = data) do
    {type, bounce_type} = classify(name, data["type"])

    event(provider(),
      type: type,
      bounce_type: bounce_type,
      message_id: message_id(data["sg_message_id"]),
      recipient: data["email"],
      timestamp: unix(data["timestamp"]),
      reason: data["reason"] || data["response"],
      url: data["url"],
      tags: List.wrap(data["category"]),
      metadata: Map.drop(data, @known_keys),
      raw: data
    )
  end

  defp to_event(data), do: event(provider(), type: :other, raw: data)

  defp classify("processed", _), do: {:accepted, nil}
  defp classify("delivered", _), do: {:delivered, nil}
  defp classify("deferred", _), do: {:deferred, nil}
  defp classify("bounce", "blocked"), do: {:bounced, :soft}
  defp classify("bounce", _), do: {:bounced, :hard}
  defp classify("dropped", _), do: {:rejected, nil}
  defp classify("open", _), do: {:opened, nil}
  defp classify("click", _), do: {:clicked, nil}
  defp classify("spamreport", _), do: {:complained, nil}
  defp classify(name, _) when name in ["unsubscribe", "group_unsubscribe"], do: {:unsubscribed, nil}
  defp classify(_, _), do: {:other, nil}

  defp message_id(id) when is_binary(id), do: id |> String.split(".", parts: 2) |> hd()
  defp message_id(_), do: nil
end
