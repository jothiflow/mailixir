defmodule Mailixir.Adapters.Scaleway do
  @moduledoc """
  Adapter for [Scaleway Transactional Email](https://www.scaleway.com/en/transactional-email-tem/) —
  `POST /transactional-email/v1alpha1/regions/{region}/emails`.

  ## Configuration

    * `:secret_key` — required, the Scaleway API secret key
    * `:project_id` — required
    * `:region` — defaults to `"fr-par"`
    * `:base_url` — defaults to `https://api.scaleway.com`
    * `:req_options` — extra `Req` options

  ## Field mapping

    * `reply_to` and `headers` → `additional_headers`
    * `tags`, `metadata` and `template` are not supported by the API and are ignored
    * inline attachments are sent as regular attachments

  ## Provider options

    * `:send_before` — RFC 3339 timestamp after which the email is not sent
  """

  use Mailixir.Adapter, provider: :scaleway, required_config: [:secret_key, :project_id]

  alias Mailixir.Adapter.HTTP
  alias Mailixir.{Address, Attachment, Email, Response}

  @default_base_url "https://api.scaleway.com"
  @default_region "fr-par"

  @impl true
  def deliver(%Email{} = email, config) do
    with {:ok, response} <- HTTP.request(provider(), config, request_options(email, config)) do
      handle_response(response)
    end
  end

  defp request_options(email, config) do
    region = Keyword.get(config, :region, @default_region)

    [
      method: :post,
      base_url: Keyword.get(config, :base_url, @default_base_url),
      url: "/transactional-email/v1alpha1/regions/#{region}/emails",
      headers: [{"x-auth-token", config[:secret_key]}],
      json: payload(email, config)
    ]
  end

  @doc false
  @spec payload(Email.t(), Mailixir.Adapter.config()) :: map()
  def payload(%Email{} = email, config) do
    HTTP.compact(%{
      project_id: config[:project_id],
      from: address(email.from),
      to: Enum.map(email.to, &address/1),
      cc: HTTP.presence(Enum.map(email.cc, &address/1)),
      bcc: HTTP.presence(Enum.map(email.bcc, &address/1)),
      subject: email.subject,
      text: email.text_body,
      html: email.html_body,
      attachments: HTTP.presence(Enum.map(email.attachments, &attachment/1)),
      additional_headers: HTTP.presence(headers(email)),
      send_before: email.provider_options[:send_before]
    })
  end

  defp address({name, email}), do: HTTP.compact(%{email: email, name: name})

  defp attachment(%Attachment{} = att),
    do: %{name: att.filename, type: att.content_type, content: Attachment.base64(att)}

  defp headers(email) do
    reply_to = if email.reply_to, do: [{"Reply-To", Address.format(email.reply_to)}], else: []
    Enum.map(reply_to ++ Map.to_list(email.headers), fn {key, value} -> %{key: key, value: value} end)
  end

  defp handle_response(%Req.Response{status: status, body: %{"emails" => [first | _]} = body})
       when status in 200..299 do
    {:ok, %Response{id: Response.normalize_id(first["message_id"] || first["id"]), provider: provider(), raw: body}}
  end

  defp handle_response(%Req.Response{status: status, body: body}) when status in 200..299 do
    {:ok, %Response{id: nil, provider: provider(), raw: body}}
  end

  defp handle_response(%Req.Response{body: body} = response) do
    {:error, HTTP.api_error(provider(), response, HTTP.error_message(body, ["message", "type"]))}
  end
end
