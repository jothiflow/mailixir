defmodule Mailixir.Adapters.Mailtrap do
  @moduledoc """
  Adapter for [Mailtrap](https://mailtrap.io) — Email Sending API, Bulk API,
  and the Sandbox (Email Testing) API.

  ## Configuration

    * `:api_key` — required, the API token
    * `:inbox_id` — when set, sends to the sandbox inbox instead of real recipients
    * `:bulk` — when `true`, uses the bulk stream endpoint
    * `:base_url` — overrides the endpoint chosen from the options above
    * `:req_options` — extra `Req` options

  ## Field mapping

    * `tags` → `category` (first tag), `metadata` → `custom_variables`
    * `template` / `template_vars` → `template_uuid` / `template_variables`
    * inline attachments → `disposition: "inline"` with `content_id`
  """

  use Mailixir.Adapter, provider: :mailtrap, required_config: [:api_key]

  alias Mailixir.Adapter.HTTP
  alias Mailixir.{Attachment, Email, Response}

  @impl true
  def deliver(%Email{} = email, config) do
    with {:ok, response} <- HTTP.request(provider(), config, request_options(email, config)) do
      handle_response(response)
    end
  end

  defp request_options(email, config) do
    {base_url, url} = endpoint(config)

    [
      method: :post,
      base_url: Keyword.get(config, :base_url, base_url),
      url: url,
      headers: [{"api-token", config[:api_key]}],
      json: payload(email)
    ]
  end

  @doc false
  @spec endpoint(Mailixir.Adapter.config()) :: {String.t(), String.t()}
  def endpoint(config) do
    cond do
      inbox = config[:inbox_id] -> {"https://sandbox.api.mailtrap.io", "/api/send/#{inbox}"}
      config[:bulk] -> {"https://bulk.api.mailtrap.io", "/api/send"}
      true -> {"https://send.api.mailtrap.io", "/api/send"}
    end
  end

  @doc false
  @spec payload(Email.t()) :: map()
  def payload(%Email{} = email) do
    HTTP.compact(%{
      from: address(email.from),
      to: Enum.map(email.to, &address/1),
      cc: HTTP.presence(Enum.map(email.cc, &address/1)),
      bcc: HTTP.presence(Enum.map(email.bcc, &address/1)),
      reply_to: email.reply_to && address(email.reply_to),
      subject: email.subject,
      text: email.text_body,
      html: email.html_body,
      headers: HTTP.presence(email.headers),
      attachments: HTTP.presence(Enum.map(email.attachments, &attachment/1)),
      category: List.first(email.tags),
      custom_variables: HTTP.presence(email.metadata),
      template_uuid: email.template,
      template_variables: if(email.template, do: HTTP.presence(email.template_vars))
    })
  end

  defp address({name, email}), do: HTTP.compact(%{email: email, name: name})

  defp attachment(%Attachment{} = att) do
    HTTP.compact(%{
      content: Attachment.base64(att),
      type: att.content_type,
      filename: att.filename,
      disposition: if(Attachment.inline?(att), do: "inline", else: "attachment"),
      content_id: if(Attachment.inline?(att), do: att.content_id)
    })
  end

  defp handle_response(%Req.Response{status: status, body: %{"success" => true} = body}) when status in 200..299 do
    {:ok, %Response{id: List.first(body["message_ids"] || []), provider: provider(), raw: body}}
  end

  defp handle_response(%Req.Response{body: %{"errors" => errors}} = response) when is_list(errors) do
    {:error, HTTP.api_error(provider(), response, Enum.map_join(errors, "; ", &to_string/1))}
  end

  defp handle_response(%Req.Response{body: body} = response) do
    {:error, HTTP.api_error(provider(), response, HTTP.error_message(body, ["error", "message"]))}
  end
end
