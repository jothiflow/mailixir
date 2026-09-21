defmodule Mailixir.Adapters.SendGrid do
  @moduledoc """
  Adapter for [SendGrid](https://sendgrid.com) — `POST /v3/mail/send`.

  ## Configuration

    * `:api_key` — required
    * `:base_url` — `https://api.sendgrid.com` (default) or `https://api.eu.sendgrid.com`
    * `:req_options` — extra `Req` options

  ## Field mapping

    * `tags` → `categories`, `metadata` → `custom_args`
    * `template` / `template_vars` → `template_id` / `personalizations[0].dynamic_template_data`
    * inline attachments → `disposition: "inline"` with `content_id`

  ## Provider options

    * `:send_at` (unix timestamp), `:batch_id`, `:asm` (`%{group_id: …}`),
      `:ip_pool_name`, `:mail_settings`, `:tracking_settings` — copied as-is

  SendGrid answers `202 Accepted` with the id in the `X-Message-Id` header.
  """

  use Mailixir.Adapter, provider: :sendgrid, required_config: [:api_key]

  alias Mailixir.Adapter.HTTP
  alias Mailixir.{Attachment, Email, Response}

  @default_base_url "https://api.sendgrid.com"
  @passthrough ~w(send_at batch_id asm ip_pool_name mail_settings tracking_settings)a

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
      url: "/v3/mail/send",
      auth: {:bearer, config[:api_key]},
      json: payload(email)
    ]
  end

  @doc false
  @spec payload(Email.t()) :: map()
  def payload(%Email{} = email) do
    %{
      personalizations: [
        HTTP.compact(%{
          to: Enum.map(email.to, &address/1),
          cc: HTTP.presence(Enum.map(email.cc, &address/1)),
          bcc: HTTP.presence(Enum.map(email.bcc, &address/1)),
          dynamic_template_data: if(email.template, do: HTTP.presence(email.template_vars))
        })
      ],
      from: address(email.from),
      reply_to: email.reply_to && address(email.reply_to),
      subject: email.subject,
      content: HTTP.presence(content(email)),
      headers: HTTP.presence(email.headers),
      attachments: HTTP.presence(Enum.map(email.attachments, &attachment/1)),
      categories: HTTP.presence(email.tags),
      custom_args: HTTP.presence(email.metadata),
      template_id: email.template
    }
    |> Map.merge(Map.take(email.provider_options, @passthrough))
    |> HTTP.compact()
  end

  defp address({name, email}), do: HTTP.compact(%{email: email, name: name})

  # SendGrid requires text/plain before text/html.
  defp content(email) do
    [
      email.text_body && %{type: "text/plain", value: email.text_body},
      email.html_body && %{type: "text/html", value: email.html_body}
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp attachment(%Attachment{} = att) do
    HTTP.compact(%{
      content: Attachment.base64(att),
      type: att.content_type,
      filename: att.filename,
      disposition: if(Attachment.inline?(att), do: "inline", else: "attachment"),
      content_id: if(Attachment.inline?(att), do: att.content_id)
    })
  end

  defp handle_response(%Req.Response{status: status} = response) when status in 200..299 do
    id = response |> Req.Response.get_header("x-message-id") |> List.first()
    {:ok, %Response{id: id, provider: provider(), raw: response.body}}
  end

  defp handle_response(%Req.Response{body: %{"errors" => errors}} = response) when is_list(errors) do
    message = Enum.map_join(errors, "; ", fn error -> error_text(error) end)
    {:error, HTTP.api_error(provider(), response, message)}
  end

  defp handle_response(%Req.Response{body: body} = response) do
    {:error, HTTP.api_error(provider(), response, HTTP.error_message(body, ["message"]))}
  end

  defp error_text(%{"message" => message, "field" => field}) when is_binary(field), do: "#{message} (#{field})"
  defp error_text(%{"message" => message}), do: message
  defp error_text(other), do: inspect(other)
end
