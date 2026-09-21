defmodule Mailixir.Adapters.Mailgun do
  @moduledoc """
  Adapter for [Mailgun](https://www.mailgun.com) —
  `POST /v3/{domain}/messages` (multipart form).

  ## Configuration

    * `:api_key` — required
    * `:domain` — required, the sending domain
    * `:base_url` — `https://api.mailgun.net` (default) or `https://api.eu.mailgun.net`
    * `:req_options` — extra `Req` options

  ## Field mapping

    * `tags` → repeated `o:tag`
    * `metadata` → `v:<key>` custom variables (returned in webhooks)
    * `headers` → `h:<Name>`
    * `template` / `template_vars` → `template` / `t:variables` (JSON)
    * inline attachments → `inline` parts, referenced from HTML as `cid:<content_id>`

  ## Provider options

  Any `o:*` Mailgun option, given as an atom: `:deliverytime`, `:testmode`,
  `:tracking`, `:"tracking-clicks"`, `:"tracking-opens"`, `:"require-tls"`,
  `:"skip-verification"`, `:"secondary-dkim"`, …
  """

  use Mailixir.Adapter, provider: :mailgun, required_config: [:api_key, :domain]

  alias Mailixir.Adapter.HTTP
  alias Mailixir.{Address, Attachment, Email, Response}

  @default_base_url "https://api.mailgun.net"

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
      url: "/v3/#{config[:domain]}/messages",
      auth: {:basic, "api:#{config[:api_key]}"},
      form_multipart: form(email)
    ]
  end

  @doc false
  @spec form(Email.t()) :: [{String.t(), term()}]
  def form(%Email{} = email) do
    Enum.concat([
      [{"from", Address.format(email.from)}],
      addresses("to", email.to),
      addresses("cc", email.cc),
      addresses("bcc", email.bcc),
      optional("h:Reply-To", email.reply_to && Address.format(email.reply_to)),
      optional("subject", email.subject),
      optional("text", email.text_body),
      optional("html", email.html_body),
      Enum.map(email.headers, fn {name, value} -> {"h:#{name}", value} end),
      Enum.map(email.attachments, &attachment/1),
      Enum.map(email.tags, &{"o:tag", &1}),
      Enum.map(email.metadata, fn {key, value} -> {"v:#{key}", value} end),
      template(email),
      Enum.map(email.provider_options, fn {key, value} -> {"o:#{key}", to_string(value)} end)
    ])
  end

  defp addresses(field, list), do: Enum.map(list, &{field, Address.format(&1)})

  defp optional(_field, nil), do: []
  defp optional(field, value), do: [{field, value}]

  defp attachment(%Attachment{} = att) do
    field = if Attachment.inline?(att), do: "inline", else: "attachment"
    filename = if Attachment.inline?(att), do: att.content_id, else: att.filename
    {field, {att.content, filename: filename, content_type: att.content_type}}
  end

  defp template(%Email{template: nil}), do: []

  defp template(%Email{template: name, template_vars: vars}) do
    [{"template", to_string(name)}] ++
      if map_size(vars) == 0, do: [], else: [{"t:variables", JSON.encode!(vars)}]
  end

  defp handle_response(%Req.Response{status: status, body: body} = response)
       when status in 200..299 do
    case body do
      %{"id" => id} -> {:ok, %Response{id: Response.normalize_id(id), provider: provider(), raw: body}}
      _ -> {:error, HTTP.api_error(provider(), response, "unexpected response body")}
    end
  end

  defp handle_response(%Req.Response{body: body} = response) do
    {:error, HTTP.api_error(provider(), response, HTTP.error_message(body, ["message", "Error"]))}
  end
end
