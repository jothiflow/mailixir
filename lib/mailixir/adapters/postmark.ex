defmodule Mailixir.Adapters.Postmark do
  @moduledoc """
  Adapter for [Postmark](https://postmarkapp.com) — `POST /email`,
  `/email/withTemplate`, and `/email/batch` for `Mailixir.deliver_many/2`.

  ## Configuration

    * `:api_key` — required, the server token
    * `:base_url` — defaults to `https://api.postmarkapp.com`
    * `:message_stream` — default stream for every email
    * `:req_options` — extra `Req` options

  ## Field mapping

    * `tags` → Postmark accepts one `Tag`; the first tag is used
    * `metadata` → `Metadata`
    * `template` → `TemplateId` (integer) or `TemplateAlias` (string), `template_vars` → `TemplateModel`
    * inline attachments → `ContentID`

  ## Provider options

    * `:message_stream`, `:track_opens`, `:track_links`, `:inline_css`
  """

  use Mailixir.Adapter, provider: :postmark, required_config: [:api_key]

  alias Mailixir.Adapter.HTTP
  alias Mailixir.{Address, Attachment, Email, Response}

  @default_base_url "https://api.postmarkapp.com"
  @message_options %{
    message_stream: "MessageStream",
    track_opens: "TrackOpens",
    track_links: "TrackLinks",
    inline_css: "InlineCss"
  }

  @impl true
  def deliver(%Email{} = email, config) do
    url = if email.template, do: "/email/withTemplate", else: "/email"

    with {:ok, response} <- HTTP.request(provider(), config, request_options(config, url, payload(email, config))) do
      handle_response(response)
    end
  end

  @impl true
  def deliver_many(emails, config) do
    {templated, plain} = Enum.split_with(emails, & &1.template)

    if templated != [] and plain != [] do
      {:error,
       Mailixir.Error.new(:unsupported, "Postmark batches cannot mix templated and non-templated emails",
         provider: provider()
       )}
    else
      url = if templated == [], do: "/email/batch", else: "/email/batchWithTemplates"
      body = Enum.map(emails, &payload(&1, config))
      body = if templated == [], do: body, else: %{"Messages" => body}

      with {:ok, response} <- HTTP.request(provider(), config, request_options(config, url, body)) do
        handle_batch_response(response)
      end
    end
  end

  defp request_options(config, url, body) do
    [
      method: :post,
      base_url: Keyword.get(config, :base_url, @default_base_url),
      url: url,
      headers: [{"x-postmark-server-token", config[:api_key]}, {"accept", "application/json"}],
      json: body
    ]
  end

  @doc false
  @spec payload(Email.t(), Mailixir.Adapter.config()) :: map()
  def payload(%Email{} = email, config) do
    %{
      "From" => Address.format(email.from),
      "To" => addresses(email.to),
      "Cc" => addresses(email.cc),
      "Bcc" => addresses(email.bcc),
      "ReplyTo" => email.reply_to && Address.format(email.reply_to),
      "Subject" => email.subject,
      "TextBody" => email.text_body,
      "HtmlBody" => email.html_body,
      "Tag" => List.first(email.tags),
      "Metadata" => HTTP.presence(email.metadata),
      "Headers" => HTTP.presence(Enum.map(email.headers, fn {k, v} -> %{"Name" => k, "Value" => v} end)),
      "Attachments" => HTTP.presence(Enum.map(email.attachments, &attachment/1)),
      "MessageStream" => config[:message_stream]
    }
    |> Map.merge(template(email))
    |> Map.merge(provider_options(email))
    |> HTTP.compact()
  end

  defp addresses([]), do: nil
  defp addresses(list), do: Enum.map_join(list, ", ", &Address.format/1)

  defp attachment(%Attachment{} = att) do
    HTTP.compact(%{
      "Name" => att.filename,
      "Content" => Attachment.base64(att),
      "ContentType" => att.content_type,
      "ContentID" => if(Attachment.inline?(att), do: "cid:" <> att.content_id)
    })
  end

  defp template(%Email{template: nil}), do: %{}

  defp template(%Email{template: id, template_vars: vars}) do
    key = if is_integer(id), do: "TemplateId", else: "TemplateAlias"
    %{key => id, "TemplateModel" => vars}
  end

  defp provider_options(%Email{provider_options: options}) do
    for {key, name} <- @message_options, Map.has_key?(options, key), into: %{}, do: {name, Map.fetch!(options, key)}
  end

  defp handle_response(%Req.Response{status: 200, body: %{"ErrorCode" => 0} = body}) do
    {:ok, %Response{id: body["MessageID"], provider: provider(), raw: body}}
  end

  defp handle_response(%Req.Response{body: body} = response) do
    {:error, HTTP.api_error(provider(), response, error_message(body))}
  end

  defp handle_batch_response(%Req.Response{status: 200, body: results} = response) when is_list(results) do
    case Enum.reject(results, &match?(%{"ErrorCode" => 0}, &1)) do
      [] -> {:ok, Enum.map(results, &%Response{id: &1["MessageID"], provider: provider(), raw: &1})}
      failed -> {:error, HTTP.api_error(provider(), response, Enum.map_join(failed, "; ", &error_message/1))}
    end
  end

  defp handle_batch_response(%Req.Response{body: body} = response) do
    {:error, HTTP.api_error(provider(), response, error_message(body))}
  end

  defp error_message(%{"ErrorCode" => code, "Message" => message}), do: "#{message} (error code #{code})"
  defp error_message(body), do: HTTP.error_message(body, ["Message", "message"])
end
