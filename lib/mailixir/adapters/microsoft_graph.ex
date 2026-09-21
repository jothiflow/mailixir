defmodule Mailixir.Adapters.MicrosoftGraph do
  @moduledoc """
  Adapter for [Microsoft Graph](https://learn.microsoft.com/graph/api/user-sendmail) —
  `POST /v1.0/me/sendMail` or `/v1.0/users/{id}/sendMail`.

  ## Configuration

    * `:access_token` — required, with the `Mail.Send` permission; a string,
      `{module, function, args}` or zero-arity function (see
      `Mailixir.Adapter.HTTP.resolve_credential/3`)
    * `:user_id` — user principal name or id; omitted, the token's own mailbox (`/me`) is used
    * `:base_url` — defaults to `https://graph.microsoft.com`
    * `:req_options` — extra `Req` options

  ## Field mapping

    * a Graph message has one body: when both are set the HTML body is sent and
      `text_body` is dropped
    * `headers` → `internetMessageHeaders` — Graph only accepts names starting with `X-`
    * `tags` → `categories`
    * `metadata` and `template` are not supported and are ignored
    * inline attachments → `isInline` + `contentId`

  ## Provider options

    * `:save_to_sent_items` — default `true`
    * `:importance` — `"low"`, `"normal"` or `"high"`

  Graph answers `202 Accepted` with no body, so the response `:id` is `nil`.
  """

  use Mailixir.Adapter, provider: :microsoft_graph, required_config: [:access_token]

  alias Mailixir.Adapter.HTTP
  alias Mailixir.{Attachment, Email, Response}

  @default_base_url "https://graph.microsoft.com"

  @impl true
  def deliver(%Email{} = email, config) do
    with {:ok, token} <- HTTP.resolve_credential(config[:access_token], provider(), :access_token),
         {:ok, response} <- HTTP.request(provider(), config, request_options(email, config, token)) do
      handle_response(response)
    end
  end

  defp request_options(email, config, token) do
    principal = if user = config[:user_id], do: "users/#{user}", else: "me"

    [
      method: :post,
      base_url: Keyword.get(config, :base_url, @default_base_url),
      url: "/v1.0/#{principal}/sendMail",
      auth: {:bearer, token},
      json: payload(email)
    ]
  end

  @doc false
  @spec payload(Email.t()) :: map()
  def payload(%Email{} = email) do
    %{
      message:
        HTTP.compact(%{
          subject: email.subject,
          body: body(email),
          from: %{emailAddress: address(email.from)},
          toRecipients: recipients(email.to),
          ccRecipients: HTTP.presence(recipients(email.cc)),
          bccRecipients: HTTP.presence(recipients(email.bcc)),
          replyTo: email.reply_to && recipients([email.reply_to]),
          internetMessageHeaders: HTTP.presence(Enum.map(email.headers, fn {k, v} -> %{name: k, value: v} end)),
          categories: HTTP.presence(email.tags),
          attachments: HTTP.presence(Enum.map(email.attachments, &attachment/1)),
          importance: email.provider_options[:importance]
        }),
      saveToSentItems: Map.get(email.provider_options, :save_to_sent_items, true)
    }
  end

  defp body(%Email{html_body: html}) when is_binary(html), do: %{contentType: "HTML", content: html}
  defp body(%Email{text_body: text}), do: %{contentType: "Text", content: text || ""}

  defp recipients(addresses), do: Enum.map(addresses, &%{emailAddress: address(&1)})
  defp address({name, email}), do: HTTP.compact(%{address: email, name: name})

  defp attachment(%Attachment{} = att) do
    HTTP.compact(%{
      "@odata.type": "#microsoft.graph.fileAttachment",
      name: att.filename,
      contentType: att.content_type,
      contentBytes: Attachment.base64(att),
      isInline: Attachment.inline?(att),
      contentId: if(Attachment.inline?(att), do: att.content_id)
    })
  end

  defp handle_response(%Req.Response{status: status, body: body}) when status in 200..299 do
    {:ok, %Response{id: nil, provider: provider(), raw: body}}
  end

  defp handle_response(%Req.Response{body: %{"error" => %{"message" => message} = error}} = response) do
    message = if code = error["code"], do: "#{code}: #{message}", else: message
    {:error, HTTP.api_error(provider(), response, message)}
  end

  defp handle_response(%Req.Response{body: body} = response) do
    {:error, HTTP.api_error(provider(), response, HTTP.error_message(body, ["message"]))}
  end
end
