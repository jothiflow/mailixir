defmodule Mailixir.Adapters.SMTP2GO do
  @moduledoc """
  Adapter for [SMTP2GO](https://www.smtp2go.com) — `POST /v3/email/send`.

  ## Configuration

    * `:api_key` — required
    * `:base_url` — defaults to `https://api.smtp2go.com`
    * `:req_options` — extra `Req` options

  ## Field mapping

    * `reply_to` and `headers` → `custom_headers`
    * `template` / `template_vars` → `template_id` / `template_data`
    * inline attachments → `inlines` (referenced as `cid:<content_id>`)
    * `tags` and `metadata` are not supported and are ignored
  """

  use Mailixir.Adapter, provider: :smtp2go, required_config: [:api_key]

  alias Mailixir.Adapter.HTTP
  alias Mailixir.{Address, Attachment, Email, Response}

  @default_base_url "https://api.smtp2go.com"

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
      url: "/v3/email/send",
      headers: [{"x-smtp2go-api-key", config[:api_key]}],
      json: payload(email)
    ]
  end

  @doc false
  @spec payload(Email.t()) :: map()
  def payload(%Email{} = email) do
    {inline, regular} = Enum.split_with(email.attachments, &Attachment.inline?/1)

    HTTP.compact(%{
      sender: Address.format(email.from),
      to: Enum.map(email.to, &Address.format/1),
      cc: HTTP.presence(Enum.map(email.cc, &Address.format/1)),
      bcc: HTTP.presence(Enum.map(email.bcc, &Address.format/1)),
      subject: email.subject,
      text_body: email.text_body,
      html_body: email.html_body,
      custom_headers: HTTP.presence(headers(email)),
      attachments: HTTP.presence(Enum.map(regular, &attachment(&1, &1.filename))),
      inlines: HTTP.presence(Enum.map(inline, &attachment(&1, &1.content_id))),
      template_id: email.template,
      template_data: if(email.template, do: HTTP.presence(email.template_vars))
    })
  end

  defp headers(email) do
    reply_to = if email.reply_to, do: [{"Reply-To", Address.format(email.reply_to)}], else: []
    Enum.map(reply_to ++ Map.to_list(email.headers), fn {header, value} -> %{header: header, value: value} end)
  end

  defp attachment(%Attachment{} = att, name),
    do: %{filename: name, fileblob: Attachment.base64(att), mimetype: att.content_type}

  defp handle_response(%Req.Response{status: status, body: %{"data" => %{"succeeded" => n} = data} = body})
       when status in 200..299 and n > 0 do
    {:ok, %Response{id: data["email_id"], provider: provider(), raw: body}}
  end

  defp handle_response(%Req.Response{body: %{"data" => %{"error" => error} = data}} = response) do
    message = if code = data["error_code"], do: "#{code}: #{error}", else: error
    {:error, HTTP.api_error(provider(), response, message)}
  end

  defp handle_response(%Req.Response{body: %{"data" => %{"failures" => [_ | _] = failures}}} = response) do
    {:error, HTTP.api_error(provider(), response, Enum.map_join(failures, "; ", &inspect/1))}
  end

  defp handle_response(%Req.Response{body: body} = response) do
    {:error, HTTP.api_error(provider(), response, HTTP.error_message(body, ["message"]))}
  end
end
