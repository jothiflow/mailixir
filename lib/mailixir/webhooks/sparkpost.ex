defmodule Mailixir.Webhooks.SparkPost do
  @moduledoc """
  Parses [SparkPost event webhooks](https://developers.sparkpost.com/api/webhooks/)
  (a JSON array of `{"msys": {...}}` batches).

  Verification: SparkPost can send either basic auth credentials or a fixed
  `Authorization` header value configured on the webhook — pass
  `basic_auth: {user, password}` or `auth_token: "…"`.

  `message_id` is the `transmission_id`, matching the id returned by
  `Mailixir.Adapters.SparkPost`; `rcpt_meta` becomes `metadata`, and
  `campaign_id` plus `rcpt_tags` become `tags`.
  """

  use Mailixir.Webhook, provider: :sparkpost

  @soft_bounce_classes ~w(20 21 22 23 24 40 70)

  @impl true
  def verify(_raw_body, _decoded, headers, config) do
    case Keyword.get(config, :auth_token) do
      nil ->
        verify_basic_auth(headers, Keyword.get(config, :basic_auth), provider())

      token ->
        if secure_compare(token, header(headers, "authorization") || ""),
          do: :ok,
          else: {:error, Mailixir.Webhook.invalid_signature(provider(), "authorization header does not match")}
    end
  end

  @impl true
  def parse(batches, _config) when is_list(batches) do
    events =
      for %{"msys" => msys} <- batches,
          {_kind, %{"type" => _} = data} <- msys,
          do: to_event(data)

    {:ok, events}
  end

  def parse(_decoded, _config), do: {:error, invalid(provider(), "expected a JSON array of msys events")}

  defp to_event(%{"type" => name} = data) do
    {type, bounce_type} = classify(name, to_string(data["bounce_class"] || ""))

    event(provider(),
      type: type,
      bounce_type: bounce_type,
      message_id: data["transmission_id"],
      recipient: data["rcpt_to"],
      timestamp: unix(data["timestamp"]),
      reason: data["reason"] || data["raw_reason"],
      url: data["target_link_url"],
      tags: List.wrap(data["campaign_id"]) ++ List.wrap(data["rcpt_tags"]),
      metadata: data["rcpt_meta"] || %{},
      raw: data
    )
  end

  defp classify("injection", _), do: {:accepted, nil}
  defp classify("delivery", _), do: {:delivered, nil}
  defp classify("delay", _), do: {:deferred, nil}
  defp classify("bounce", class) when class in @soft_bounce_classes, do: {:bounced, :soft}
  defp classify("bounce", _), do: {:bounced, :hard}
  defp classify("out_of_band", class) when class in @soft_bounce_classes, do: {:bounced, :soft}
  defp classify("out_of_band", _), do: {:bounced, :hard}
  defp classify("spam_complaint", _), do: {:complained, nil}

  defp classify(name, _) when name in ["policy_rejection", "generation_failure", "generation_rejection"],
    do: {:rejected, nil}

  defp classify(name, _) when name in ["open", "initial_open", "amp_open", "amp_initial_open"], do: {:opened, nil}
  defp classify(name, _) when name in ["click", "amp_click"], do: {:clicked, nil}
  defp classify(name, _) when name in ["list_unsubscribe", "link_unsubscribe"], do: {:unsubscribed, nil}
  defp classify(_, _), do: {:other, nil}
end
