defmodule Mailixir.Adapters.SparkPost do
  @moduledoc """
  Adapter for [SparkPost](https://www.sparkpost.com) — `POST /api/v1/transmissions`.

  ## Configuration

    * `:api_key` — required
    * `:base_url` — `https://api.sparkpost.com` (default) or `https://api.eu.sparkpost.com`
    * `:req_options` — extra `Req` options

  ## Field mapping

    * Cc and Bcc recipients are added to `recipients` with `header_to` set to
      the visible To list; Cc addresses are also written to the `CC` header, as
      SparkPost's API requires
    * `tags` → `campaign_id` (first tag), `metadata` → `metadata`
    * `template` / `template_vars` → `content.template_id` / `substitution_data`
    * inline attachments → `content.inline_images`

  ## Provider options

    * `:options` — SparkPost transmission options map (`%{open_tracking: true, transactional: true}`)
    * `:campaign_id`, `:description`, `:return_path`
  """

  use Mailixir.Adapter, provider: :sparkpost, required_config: [:api_key]

  alias Mailixir.Adapter.HTTP
  alias Mailixir.{Address, Attachment, Email, Response}

  @default_base_url "https://api.sparkpost.com"

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
      url: "/api/v1/transmissions",
      headers: [{"authorization", config[:api_key]}],
      json: payload(email)
    ]
  end

  @doc false
  @spec payload(Email.t()) :: map()
  def payload(%Email{} = email) do
    options = email.provider_options

    HTTP.compact(%{
      options: options[:options],
      campaign_id: options[:campaign_id] || List.first(email.tags),
      description: options[:description],
      return_path: options[:return_path],
      metadata: HTTP.presence(email.metadata),
      substitution_data: if(email.template, do: HTTP.presence(email.template_vars)),
      recipients: recipients(email),
      content: content(email)
    })
  end

  defp recipients(email) do
    header_to = Enum.map_join(email.to, ",", &Address.format/1)

    Enum.map(email.to, &%{address: address(&1)}) ++
      Enum.map(email.cc ++ email.bcc, &%{address: Map.put(address(&1), :header_to, header_to)})
  end

  defp address({name, email}), do: HTTP.compact(%{email: email, name: name})

  defp content(%Email{template: template} = email) when not is_nil(template) do
    HTTP.compact(%{template_id: to_string(template), use_draft_template: email.provider_options[:use_draft_template]})
  end

  defp content(email) do
    {inline, regular} = Enum.split_with(email.attachments, &Attachment.inline?/1)

    HTTP.compact(%{
      from: address(email.from),
      subject: email.subject,
      reply_to: email.reply_to && Address.format(email.reply_to),
      headers: HTTP.presence(headers(email)),
      text: email.text_body,
      html: email.html_body,
      attachments: HTTP.presence(Enum.map(regular, &attachment/1)),
      inline_images: HTTP.presence(Enum.map(inline, &attachment/1))
    })
  end

  defp headers(%Email{cc: []} = email), do: email.headers
  defp headers(%Email{cc: cc} = email), do: Map.put(email.headers, "CC", Enum.map_join(cc, ",", &Address.format/1))

  defp attachment(%Attachment{} = att) do
    name = if Attachment.inline?(att), do: att.content_id, else: att.filename
    %{name: name, type: att.content_type, data: Attachment.base64(att)}
  end

  defp handle_response(%Req.Response{status: status, body: %{"results" => results}}) when status in 200..299 do
    {:ok, %Response{id: results["id"], provider: provider(), raw: results}}
  end

  defp handle_response(%Req.Response{body: %{"errors" => errors}} = response) when is_list(errors) do
    message = Enum.map_join(errors, "; ", &(&1["description"] || &1["message"] || inspect(&1)))
    {:error, HTTP.api_error(provider(), response, message)}
  end

  defp handle_response(%Req.Response{body: body} = response) do
    {:error, HTTP.api_error(provider(), response, HTTP.error_message(body, ["message"]))}
  end
end
