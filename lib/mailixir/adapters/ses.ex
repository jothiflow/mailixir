defmodule Mailixir.Adapters.SES do
  @moduledoc """
  Adapter for [Amazon SES](https://aws.amazon.com/ses/) — SES v2
  `POST /v2/email/outbound-emails`, signed with AWS Signature V4 by `Req`.

  ## Configuration

    * `:access_key_id` — required
    * `:secret_access_key` — required
    * `:region` — required (e.g. `"eu-west-1"`)
    * `:session_token` — for temporary STS credentials
    * `:base_url` — defaults to `https://email.<region>.amazonaws.com`
    * `:configuration_set` — default `ConfigurationSetName` for every email
    * `:req_options` — extra `Req` options

  ## Field mapping

    * `tags` → `EmailTags` `[{Name: "tag", Value: tag}]`, `metadata` → `[{Name: key, Value: value}]`.
      SES restricts names and values to ASCII letters, digits, `_` and `-`.
    * attachments use SES v2 native `Attachments` (inline ones get `ContentDisposition: INLINE`)
    * `template` / `template_vars` → `Content.Template` with JSON `TemplateData`

  ## Provider options

    * `:configuration_set` — overrides the config-level default
    * `:feedback_forwarding_email_address`
    * `:list_management_options` — `%{ContactListName:, TopicName:}` map
  """

  use Mailixir.Adapter,
    provider: :ses,
    required_config: [:access_key_id, :secret_access_key, :region]

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
      base_url: Keyword.get(config, :base_url, "https://email.#{config[:region]}.amazonaws.com"),
      url: "/v2/email/outbound-emails",
      aws_sigv4: [
        access_key_id: config[:access_key_id],
        secret_access_key: config[:secret_access_key],
        token: config[:session_token],
        service: "ses",
        region: config[:region]
      ],
      json: payload(email, config)
    ]
  end

  @doc false
  @spec payload(Email.t(), Mailixir.Adapter.config()) :: map()
  def payload(%Email{} = email, config) do
    options = email.provider_options

    HTTP.compact(%{
      "FromEmailAddress" => Address.format(email.from),
      "Destination" =>
        HTTP.compact(%{
          "ToAddresses" => HTTP.presence(Enum.map(email.to, &Address.format/1)),
          "CcAddresses" => HTTP.presence(Enum.map(email.cc, &Address.format/1)),
          "BccAddresses" => HTTP.presence(Enum.map(email.bcc, &Address.format/1))
        }),
      "ReplyToAddresses" => email.reply_to && [Address.format(email.reply_to)],
      "Content" => content(email),
      "EmailTags" => HTTP.presence(tags(email)),
      "ConfigurationSetName" => Map.get(options, :configuration_set, config[:configuration_set]),
      "FeedbackForwardingEmailAddress" => options[:feedback_forwarding_email_address],
      "ListManagementOptions" => options[:list_management_options]
    })
  end

  defp content(%Email{template: nil} = email) do
    %{
      "Simple" =>
        HTTP.compact(%{
          "Subject" => %{"Data" => email.subject, "Charset" => "UTF-8"},
          "Body" =>
            HTTP.compact(%{
              "Text" => email.text_body && %{"Data" => email.text_body, "Charset" => "UTF-8"},
              "Html" => email.html_body && %{"Data" => email.html_body, "Charset" => "UTF-8"}
            }),
          "Headers" => headers(email),
          "Attachments" => attachments(email)
        })
    }
  end

  defp content(%Email{template: name, template_vars: vars} = email) do
    %{
      "Template" =>
        HTTP.compact(%{
          "TemplateName" => to_string(name),
          "TemplateData" => JSON.encode!(vars),
          "Headers" => headers(email),
          "Attachments" => attachments(email)
        })
    }
  end

  defp headers(%Email{headers: headers}) do
    HTTP.presence(Enum.map(headers, fn {name, value} -> %{"Name" => name, "Value" => value} end))
  end

  defp attachments(%Email{attachments: attachments}),
    do: HTTP.presence(Enum.map(attachments, &attachment/1))

  defp attachment(%Attachment{} = att) do
    HTTP.compact(%{
      "FileName" => att.filename,
      "ContentType" => att.content_type,
      "RawContent" => Attachment.base64(att),
      "ContentTransferEncoding" => "BASE64",
      "ContentDisposition" => if(Attachment.inline?(att), do: "INLINE", else: "ATTACHMENT"),
      "ContentId" => if(Attachment.inline?(att), do: att.content_id)
    })
  end

  defp tags(email) do
    Enum.map(email.tags, &%{"Name" => "tag", "Value" => &1}) ++
      Enum.map(email.metadata, fn {k, v} -> %{"Name" => k, "Value" => v} end)
  end

  defp handle_response(%Req.Response{status: status, body: body}) when status in 200..299 do
    {:ok, %Response{id: if(is_map(body), do: body["MessageId"]), provider: provider(), raw: body}}
  end

  defp handle_response(%Req.Response{body: body} = response) do
    type = Req.Response.get_header(response, "x-amzn-errortype")
    message = HTTP.error_message(body, ["message", "Message"])
    message = if type == [], do: message, else: "#{hd(type)}: #{message}"
    {:error, HTTP.api_error(provider(), response, message)}
  end
end
