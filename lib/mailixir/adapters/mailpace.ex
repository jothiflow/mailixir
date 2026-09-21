defmodule Mailixir.Adapters.MailPace do
  @moduledoc """
  Adapter for [MailPace](https://mailpace.com) — `POST /api/v1/send`.

  ## Configuration

    * `:api_key` — required, the server token
    * `:base_url` — defaults to `https://app.mailpace.com`
    * `:req_options` — extra `Req` options

  ## Field mapping

    * `tags` → `tags`; `metadata` and `template` are not supported
    * `headers` → not supported by the API; use the provider options below
    * inline attachments → `cid`

  ## Provider options

    * `:list_unsubscribe`, `:in_reply_to`, `:references`
  """

  use Mailixir.Adapter, provider: :mailpace, required_config: [:api_key]

  alias Mailixir.Adapter.HTTP
  alias Mailixir.{Address, Attachment, Email, Response}

  @default_base_url "https://app.mailpace.com"

  @impl true
  def deliver(%Email{} = email, config) do
    with {:ok, response} <- HTTP.request(provider(), config, request_options(email, config)) do
      handle_response(response)
    end
  end

  defp request_options(email, config) do
    [
      method: :post,
      base_url: Keyword.get(config, :base_url, @default_base_url),
      url: "/api/v1/send",
      headers: [{"mailpace-server-token", config[:api_key]}],
      json: payload(email)
    ]
  end

  @doc false
  @spec payload(Email.t()) :: map()
  def payload(%Email{} = email) do
    options = email.provider_options

    HTTP.compact(%{
      from: Address.format(email.from),
      to: addresses(email.to),
      cc: addresses(email.cc),
      bcc: addresses(email.bcc),
      replyto: email.reply_to && Address.format(email.reply_to),
      subject: email.subject,
      htmlbody: email.html_body,
      textbody: email.text_body,
      tags: HTTP.presence(email.tags),
      attachments: HTTP.presence(Enum.map(email.attachments, &attachment/1)),
      list_unsubscribe: options[:list_unsubscribe],
      inreplyto: options[:in_reply_to],
      references: options[:references]
    })
  end

  defp addresses([]), do: nil
  defp addresses(list), do: Enum.map_join(list, ", ", &Address.format/1)

  defp attachment(%Attachment{} = att) do
    HTTP.compact(%{
      name: att.filename,
      content: Attachment.base64(att),
      content_type: att.content_type,
      cid: if(Attachment.inline?(att), do: att.content_id)
    })
  end

  defp handle_response(%Req.Response{status: status, body: %{"id" => id} = body}) when status in 200..299 do
    {:ok, %Response{id: to_string(id), provider: provider(), raw: body}}
  end

  defp handle_response(%Req.Response{body: %{"errors" => errors}} = response) when is_map(errors) do
    message =
      Enum.map_join(errors, "; ", fn {field, messages} -> "#{field}: #{Enum.join(List.wrap(messages), ", ")}" end)

    {:error, HTTP.api_error(provider(), response, message)}
  end

  defp handle_response(%Req.Response{body: body} = response) do
    {:error, HTTP.api_error(provider(), response, HTTP.error_message(body, ["error", "message"]))}
  end
end
