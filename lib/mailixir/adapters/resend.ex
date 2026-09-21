defmodule Mailixir.Adapters.Resend do
  @moduledoc """
  Adapter for [Resend](https://resend.com) — `POST /emails`.

  ## Configuration

    * `:api_key` — required
    * `:base_url` — defaults to `https://api.resend.com`
    * `:req_options` — extra `Req` options

  ## Field mapping

    * `tags` → `[{name: "tag", value: tag}]`, `metadata` → `[{name: key, value: value}]`.
      Resend only allows ASCII letters, numbers, `_` and `-` in tag names and values.
    * `template` / `template_vars` → `template.id` / `template.variables`
    * inline attachments are sent with their `content_id`

  ## Provider options

    * `:scheduled_at` — natural language or ISO 8601 (`"in 1 hour"`)
    * `:idempotency_key` — sent as the `Idempotency-Key` header
  """

  use Mailixir.Adapter, provider: :resend, required_config: [:api_key]

  alias Mailixir.Adapter.HTTP
  alias Mailixir.{Address, Attachment, Email, Response}

  @default_base_url "https://api.resend.com"

  @impl true
  def deliver(%Email{} = email, config) do
    with {:ok, response} <- HTTP.request(provider(), config, request_options(email, config)) do
      handle_response(response)
    end
  end

  defp request_options(email, config) do
    headers =
      [authorization: "Bearer #{config[:api_key]}"] ++
        case email.provider_options[:idempotency_key] do
          nil -> []
          key -> [{"idempotency-key", key}]
        end

    [
      method: :post,
      base_url: Keyword.get(config, :base_url, @default_base_url),
      url: "/emails",
      headers: headers,
      json: payload(email)
    ]
  end

  @doc false
  @spec payload(Email.t()) :: map()
  def payload(%Email{} = email) do
    %{
      from: Address.format(email.from),
      to: Enum.map(email.to, &Address.format/1),
      cc: HTTP.presence(Enum.map(email.cc, &Address.format/1)),
      bcc: HTTP.presence(Enum.map(email.bcc, &Address.format/1)),
      reply_to: email.reply_to && Address.format(email.reply_to),
      subject: email.subject,
      html: email.html_body,
      text: email.text_body,
      headers: HTTP.presence(email.headers),
      attachments: HTTP.presence(Enum.map(email.attachments, &attachment/1)),
      tags: HTTP.presence(tags(email)),
      template: template(email),
      scheduled_at: email.provider_options[:scheduled_at]
    }
    |> HTTP.compact()
  end

  defp attachment(%Attachment{} = att) do
    HTTP.compact(%{
      filename: att.filename,
      content: Attachment.base64(att),
      content_type: att.content_type,
      content_id: if(Attachment.inline?(att), do: att.content_id)
    })
  end

  defp tags(email) do
    Enum.map(email.tags, &%{name: "tag", value: &1}) ++
      Enum.map(email.metadata, fn {k, v} -> %{name: k, value: v} end)
  end

  defp template(%Email{template: nil}), do: nil

  defp template(%Email{template: id, template_vars: vars}),
    do: HTTP.compact(%{id: id, variables: HTTP.presence(vars)})

  defp handle_response(%Req.Response{status: status, body: %{"id" => id} = body})
       when status in 200..299 do
    {:ok, %Response{id: id, provider: provider(), raw: body}}
  end

  defp handle_response(%Req.Response{body: body} = response) do
    {:error, HTTP.api_error(provider(), response, HTTP.error_message(body, ["message", "name"]))}
  end
end
