defmodule Mailixir.Adapters.Facteur do
  @moduledoc """
  Adapter for [Facteur](https://github.com/florentroques/facteur), a
  self-hosted delivery platform — `POST /api/v1/emails`.

  ## Configuration

    * `:api_key` — required, a workspace API key (sent as `Bearer`)
    * `:base_url` — required, your Facteur instance (e.g. `https://mail.acme.com`)
    * `:req_options` — extra `Req` options

  ## Field mapping

  Facteur speaks Mailixir's own vocabulary, so every field maps directly:
  `tags` and `metadata` are sent as-is and come back on every
  `Mailixir.Event`, which is how a caller correlates events to its records.
  Templates are not supported — Facteur delivers what it is given, so
  rendering belongs above it; a templated email returns `:unsupported`.

  ## Provider options

    * `:idempotency_key` — sent as the `Idempotency-Key` header. Reusing one
      returns the original message (HTTP 200 instead of 202) rather than
      sending twice, so a timed-out send is safe to retry.

  Accepting a message only queues it: per-recipient outcomes arrive later as
  webhooks, parsed by `Mailixir.Webhooks.Facteur`.
  """

  use Mailixir.Adapter, provider: :facteur, required_config: [:api_key, :base_url]

  alias Mailixir.Adapter.HTTP
  alias Mailixir.{Address, Attachment, Email, Error, Response}

  @impl true
  def deliver(%Email{template: template}, _config) when not is_nil(template) do
    {:error, Error.new(:unsupported, "Facteur has no template rendering; render before sending", provider: provider())}
  end

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
      base_url: Keyword.fetch!(config, :base_url),
      url: "/api/v1/emails",
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
      text: email.text_body,
      html: email.html_body,
      headers: HTTP.presence(email.headers),
      attachments: HTTP.presence(Enum.map(email.attachments, &attachment/1)),
      tags: HTTP.presence(email.tags),
      metadata: HTTP.presence(email.metadata)
    }
    |> HTTP.compact()
  end

  defp attachment(%Attachment{} = att) do
    HTTP.compact(%{
      filename: att.filename,
      content_type: att.content_type,
      content: Attachment.base64(att),
      disposition: if(Attachment.inline?(att), do: "inline"),
      content_id: if(Attachment.inline?(att), do: att.content_id)
    })
  end

  defp handle_response(%Req.Response{body: %{"data" => %{"id" => id} = data}} = response) do
    if HTTP.success?(response) do
      {:ok, %Response{id: id, provider: provider(), raw: data}}
    else
      {:error, error(response)}
    end
  end

  defp handle_response(%Req.Response{} = response), do: {:error, error(response)}

  # Facteur always answers with {"error": {"type", "message", "details"?}}.
  defp error(%Req.Response{body: body} = response) do
    message =
      case body do
        %{"error" => %{} = error} -> HTTP.error_message(error, ["message", "type"])
        other -> HTTP.error_message(other, ["message"])
      end

    HTTP.api_error(provider(), response, message)
  end
end
