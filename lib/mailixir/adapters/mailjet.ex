defmodule Mailixir.Adapters.Mailjet do
  @moduledoc """
  Adapter for [Mailjet](https://www.mailjet.com) — Send API `POST /v3.1/send`.

  ## Configuration

    * `:api_key` — required (public key)
    * `:secret_key` — required (private key)
    * `:base_url` — defaults to `https://api.mailjet.com`
    * `:req_options` — extra `Req` options

  ## Field mapping

    * `metadata` → JSON-encoded `EventPayload`, returned in webhook events
    * `tags` → Mailjet's Send API has no tag concept; tags are **ignored**.
      Use the `:custom_campaign` provider option to group messages in statistics.
    * `template` (integer id) / `template_vars` → `TemplateID` + `TemplateLanguage: true` / `Variables`
    * inline attachments → `InlinedAttachments` with `ContentID`

  ## Provider options

    * `:custom_id`, `:custom_campaign`, `:deduplicate_campaign`, `:url_tags`,
      `:priority`, `:monitoring_category` — copied to the message as-is
    * `:sandbox_mode` — validates the message without sending it

  The response `:id` is the `MessageUUID` of the first recipient; the full
  per-recipient breakdown is in `:raw`.

  `Mailixir.deliver_many/2` sends up to #{50} emails per request through the
  same endpoint's `Messages` array.
  """

  use Mailixir.Adapter, provider: :mailjet, required_config: [:api_key, :secret_key]

  alias Mailixir.Adapter.HTTP
  alias Mailixir.{Attachment, Email, Response}

  @default_base_url "https://api.mailjet.com"
  @batch_size 50

  @message_options %{
    custom_id: "CustomID",
    custom_campaign: "CustomCampaign",
    deduplicate_campaign: "DeduplicateCampaign",
    url_tags: "URLTags",
    priority: "Priority",
    monitoring_category: "MonitoringCategory"
  }

  @impl true
  def deliver(%Email{} = email, config) do
    with {:ok, response} <- HTTP.request(provider(), config, request_options(config, payload(email))),
         {:ok, [result]} <- handle_response(response, 1) do
      {:ok, result}
    else
      {:error, %Mailixir.Error{} = error} -> {:error, error}
      {:error, [{:error, error}]} -> {:error, error}
    end
  end

  @impl true
  def deliver_many(emails, config) do
    emails
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      with {:ok, response} <- HTTP.request(provider(), config, request_options(config, batch_payload(chunk))),
           {:ok, results} <- handle_response(response, length(chunk)) do
        {:cont, {:ok, acc ++ results}}
      else
        {:error, %Mailixir.Error{} = error} ->
          {:halt, {:error, error}}

        {:error, results} ->
          done = Enum.map(acc, &{:ok, &1})
          failed = Enum.count(results, &match?({:error, _}, &1))

          {:halt,
           {:error,
            Mailixir.Error.new(:batch_failure, "#{failed} of #{length(chunk)} emails failed in a Mailjet batch",
              provider: provider(),
              details: done ++ results
            )}}
      end
    end)
  end

  defp request_options(config, body) do
    [
      method: :post,
      base_url: Keyword.get(config, :base_url, @default_base_url),
      url: "/v3.1/send",
      auth: {:basic, "#{config[:api_key]}:#{config[:secret_key]}"},
      json: body
    ]
  end

  @doc false
  @spec payload(Email.t()) :: map()
  def payload(%Email{} = email) do
    HTTP.compact(%{
      "Messages" => [message(email)],
      "SandboxMode" => email.provider_options[:sandbox_mode]
    })
  end

  defp batch_payload(emails) do
    HTTP.compact(%{
      "Messages" => Enum.map(emails, &message/1),
      "SandboxMode" => Enum.any?(emails, & &1.provider_options[:sandbox_mode])
    })
  end

  defp message(email) do
    {inline, regular} = Enum.split_with(email.attachments, &Attachment.inline?/1)

    %{
      "From" => address(email.from),
      "To" => Enum.map(email.to, &address/1),
      "Cc" => HTTP.presence(Enum.map(email.cc, &address/1)),
      "Bcc" => HTTP.presence(Enum.map(email.bcc, &address/1)),
      "ReplyTo" => email.reply_to && address(email.reply_to),
      "Subject" => email.subject,
      "TextPart" => email.text_body,
      "HTMLPart" => email.html_body,
      "Headers" => HTTP.presence(email.headers),
      "Attachments" => HTTP.presence(Enum.map(regular, &attachment/1)),
      "InlinedAttachments" => HTTP.presence(Enum.map(inline, &attachment/1)),
      "EventPayload" => if(map_size(email.metadata) > 0, do: JSON.encode!(email.metadata))
    }
    |> Map.merge(template(email))
    |> Map.merge(provider_options(email))
    |> HTTP.compact()
  end

  defp address({name, email}), do: HTTP.compact(%{"Email" => email, "Name" => name})

  defp attachment(%Attachment{} = att) do
    HTTP.compact(%{
      "ContentType" => att.content_type,
      "Filename" => att.filename,
      "Base64Content" => Attachment.base64(att),
      "ContentID" => if(Attachment.inline?(att), do: att.content_id)
    })
  end

  defp template(%Email{template: nil}), do: %{}

  defp template(%Email{template: id, template_vars: vars}) do
    %{"TemplateID" => id, "TemplateLanguage" => true, "Variables" => HTTP.presence(vars)}
  end

  defp provider_options(%Email{provider_options: options}) do
    for {key, name} <- @message_options, Map.has_key?(options, key), into: %{} do
      {name, Map.fetch!(options, key)}
    end
  end

  # Mailjet answers per message, in order, with HTTP 200 or 400 depending on
  # whether every message succeeded. Returns {:ok, responses} when all did, or
  # {:error, per_message_results} when some failed.
  defp handle_response(%Req.Response{body: %{"Messages" => messages} = body} = response, expected)
       when is_list(messages) and length(messages) == expected do
    results = Enum.map(messages, &message_result(&1, body, response))

    if Enum.all?(results, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(results, fn {:ok, r} -> r end)},
      else: {:error, results}
  end

  defp handle_response(%Req.Response{body: body} = response, _expected) do
    {:error, HTTP.api_error(provider(), response, HTTP.error_message(body, ["ErrorMessage", "message"]))}
  end

  defp message_result(%{"Status" => "success"} = message, body, _response) do
    {:ok, %Response{id: get_in(message, ["To", Access.at(0), "MessageUUID"]), provider: provider(), raw: body}}
  end

  defp message_result(%{"Errors" => errors}, _body, response) do
    {:error, HTTP.api_error(provider(), response, Enum.map_join(errors, "; ", &error_text/1))}
  end

  defp message_result(message, _body, response) do
    {:error, HTTP.api_error(provider(), response, "unexpected message status #{inspect(message["Status"])}")}
  end

  defp error_text(%{"ErrorMessage" => message} = error) do
    case error["ErrorRelatedTo"] do
      related when is_list(related) and related != [] ->
        "#{message} (#{Enum.join(related, ", ")})"

      _ ->
        message
    end
  end

  defp error_text(other), do: inspect(other)
end
