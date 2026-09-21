defmodule Mailixir.Adapters.Brevo do
  @moduledoc """
  Adapter for [Brevo](https://www.brevo.com) (formerly Sendinblue) —
  `POST /v3/smtp/email`.

  ## Configuration

    * `:api_key` — required (`xkeysib-…`)
    * `:base_url` — defaults to `https://api.brevo.com`
    * `:req_options` — extra `Req` options

  ## Field mapping

    * `tags` → `tags`
    * `metadata` → JSON-encoded into the `X-Mailin-custom` header, which Brevo
      echoes back in webhook events
    * `template` (integer id) / `template_vars` → `templateId` / `params`
    * attachments are sent base64-encoded; Brevo has no dedicated inline-image
      field, so inline attachments are delivered as regular attachments

  ## Provider options

    * `:scheduled_at` — ISO 8601 datetime string
    * `:batch_id` — groups scheduled emails for later cancellation
  """

  use Mailixir.Adapter, provider: :brevo, required_config: [:api_key]

  alias Mailixir.Adapter.HTTP
  alias Mailixir.{Attachment, Email, Response}

  @default_base_url "https://api.brevo.com"

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
      url: "/v3/smtp/email",
      headers: [{"api-key", config[:api_key]}],
      json: payload(email)
    ]
  end

  @doc false
  @spec payload(Email.t()) :: map()
  def payload(%Email{} = email) do
    %{
      sender: address(email.from),
      to: Enum.map(email.to, &address/1),
      cc: HTTP.presence(Enum.map(email.cc, &address/1)),
      bcc: HTTP.presence(Enum.map(email.bcc, &address/1)),
      replyTo: email.reply_to && address(email.reply_to),
      subject: email.subject,
      htmlContent: email.html_body,
      textContent: email.text_body,
      headers: HTTP.presence(headers(email)),
      attachment: HTTP.presence(Enum.map(email.attachments, &attachment/1)),
      tags: HTTP.presence(email.tags),
      templateId: email.template,
      params: if(email.template, do: HTTP.presence(email.template_vars)),
      scheduledAt: email.provider_options[:scheduled_at],
      batchId: email.provider_options[:batch_id]
    }
    |> HTTP.compact()
  end

  defp address({name, email}), do: HTTP.compact(%{name: name, email: email})

  defp attachment(%Attachment{} = att), do: %{name: att.filename, content: Attachment.base64(att)}

  defp headers(%Email{metadata: metadata} = email) when map_size(metadata) == 0, do: email.headers

  defp headers(%Email{} = email) do
    Map.put(email.headers, "X-Mailin-custom", JSON.encode!(email.metadata))
  end

  defp handle_response(%Req.Response{status: status, body: %{"messageId" => id} = body})
       when status in 200..299 do
    {:ok, %Response{id: Response.normalize_id(id), provider: provider(), raw: body}}
  end

  defp handle_response(%Req.Response{status: status, body: body}) when status in 200..299 do
    {:ok, %Response{id: nil, provider: provider(), raw: body}}
  end

  defp handle_response(%Req.Response{body: body} = response) do
    {:error, HTTP.api_error(provider(), response, HTTP.error_message(body, ["message", "code"]))}
  end
end
