defmodule Mailixir.Adapters.Postal do
  @moduledoc """
  Adapter for self-hosted [Postal](https://postalserver.io) —
  `POST /api/v1/send/message`.

  ## Configuration

    * `:api_key` — required, a server API key
    * `:base_url` — required, your Postal installation (`https://postal.example.com`)
    * `:req_options` — extra `Req` options

  ## Field mapping

    * `tags` → `tag` (first tag); `metadata` and `template` are not supported
    * inline attachments are sent as regular attachments (Postal has no inline field)

  ## Provider options

    * `:bounce` — mark the message as a bounce
    * `:sender` — the `Sender` header

  Postal returns HTTP 200 for application errors too; the adapter inspects
  the `status` field.
  """

  use Mailixir.Adapter, provider: :postal, required_config: [:api_key, :base_url]

  alias Mailixir.Adapter.HTTP
  alias Mailixir.{Address, Attachment, Email, Response}

  @impl true
  def deliver(%Email{} = email, config) do
    with {:ok, response} <- HTTP.request(provider(), config, request_options(email, config)) do
      handle_response(response)
    end
  end

  defp request_options(email, config) do
    [
      method: :post,
      base_url: config[:base_url],
      url: "/api/v1/send/message",
      headers: [{"x-server-api-key", config[:api_key]}],
      json: payload(email)
    ]
  end

  @doc false
  @spec payload(Email.t()) :: map()
  def payload(%Email{} = email) do
    HTTP.compact(%{
      from: Address.format(email.from),
      sender: email.provider_options[:sender],
      to: Enum.map(email.to, &Address.format/1),
      cc: HTTP.presence(Enum.map(email.cc, &Address.format/1)),
      bcc: HTTP.presence(Enum.map(email.bcc, &Address.format/1)),
      reply_to: email.reply_to && Address.format(email.reply_to),
      subject: email.subject,
      tag: List.first(email.tags),
      plain_body: email.text_body,
      html_body: email.html_body,
      headers: HTTP.presence(email.headers),
      attachments: HTTP.presence(Enum.map(email.attachments, &attachment/1)),
      bounce: email.provider_options[:bounce]
    })
  end

  defp attachment(%Attachment{} = att),
    do: %{name: att.filename, content_type: att.content_type, data: Attachment.base64(att)}

  defp handle_response(%Req.Response{status: 200, body: %{"status" => "success", "data" => data} = body}) do
    {:ok, %Response{id: Response.normalize_id(data["message_id"]), provider: provider(), raw: body}}
  end

  defp handle_response(%Req.Response{body: %{"status" => _, "data" => %{"message" => message} = data}} = response) do
    message = if code = data["code"], do: "#{code}: #{message}", else: message
    {:error, HTTP.api_error(provider(), response, message)}
  end

  defp handle_response(%Req.Response{body: body} = response) do
    {:error, HTTP.api_error(provider(), response, HTTP.error_message(body, ["message"]))}
  end
end
