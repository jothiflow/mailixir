defmodule Mailixir.Adapters.Mandrill do
  @moduledoc """
  Adapter for [Mailchimp Transactional](https://mailchimp.com/developer/transactional/)
  (Mandrill) — `POST /messages/send` or `/messages/send-template`.

  ## Configuration

    * `:api_key` — required
    * `:base_url` — defaults to `https://mandrillapp.com/api/1.0`
    * `:req_options` — extra `Req` options

  ## Field mapping

    * `tags` → `tags`, `metadata` → `metadata`
    * `reply_to` → `headers["Reply-To"]`
    * inline attachments → `images` (referenced as `cid:<content_id>`)
    * `template` (template slug) / `template_vars` → `send-template` with
      `global_merge_vars`

  ## Provider options

    * message-level: `:important`, `:track_opens`, `:track_clicks`, `:auto_text`,
      `:auto_html`, `:inline_css`, `:url_strip_qs`, `:preserve_recipients`,
      `:view_content_link`, `:bcc_address`, `:tracking_domain`,
      `:signing_domain`, `:return_path_domain`, `:merge_language`, `:subaccount`,
      `:google_analytics_domains`, `:google_analytics_campaign`
    * request-level: `:async`, `:ip_pool`, `:send_at`
    * `:template_content` — list of `%{name:, content:}` editable regions for templates

  Mandrill reports per-recipient status. The response `:id` is the first
  recipient's `_id`; delivery is an error when any recipient is `rejected` or
  `invalid` (details carry the full per-recipient list).
  """

  use Mailixir.Adapter, provider: :mandrill, required_config: [:api_key]

  alias Mailixir.Adapter.HTTP
  alias Mailixir.{Address, Attachment, Email, Response}

  @default_base_url "https://mandrillapp.com/api/1.0"

  @message_options ~w(important track_opens track_clicks auto_text auto_html inline_css url_strip_qs
    preserve_recipients view_content_link bcc_address tracking_domain signing_domain return_path_domain
    merge_language subaccount google_analytics_domains google_analytics_campaign)a

  @request_options ~w(async ip_pool send_at)a

  @ok_statuses ~w(sent queued scheduled)

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
      url: if(email.template, do: "/messages/send-template", else: "/messages/send"),
      json: payload(email, config[:api_key])
    ]
  end

  @doc false
  @spec payload(Email.t(), String.t()) :: map()
  def payload(%Email{} = email, api_key) do
    %{key: api_key, message: message(email)}
    |> Map.merge(template(email))
    |> Map.merge(Map.take(email.provider_options, @request_options))
  end

  defp message(email) do
    {inline, regular} = Enum.split_with(email.attachments, &Attachment.inline?/1)

    %{
      from_email: Address.email(email.from),
      from_name: Address.name(email.from),
      to: recipients(email),
      subject: email.subject,
      text: email.text_body,
      html: email.html_body,
      headers: HTTP.presence(headers(email)),
      attachments: HTTP.presence(Enum.map(regular, &attachment/1)),
      images: HTTP.presence(Enum.map(inline, &attachment/1)),
      tags: HTTP.presence(email.tags),
      metadata: HTTP.presence(email.metadata),
      global_merge_vars: merge_vars(email)
    }
    |> Map.merge(Map.take(email.provider_options, @message_options))
    |> HTTP.compact()
  end

  defp recipients(email) do
    for {type, list} <- [to: email.to, cc: email.cc, bcc: email.bcc], {name, address} <- list do
      HTTP.compact(%{email: address, name: name, type: type})
    end
  end

  defp headers(%Email{reply_to: nil} = email), do: email.headers

  defp headers(%Email{reply_to: reply_to} = email),
    do: Map.put(email.headers, "Reply-To", Address.format(reply_to))

  defp attachment(%Attachment{} = att) do
    name = if Attachment.inline?(att), do: att.content_id, else: att.filename
    %{type: att.content_type, name: name, content: Attachment.base64(att)}
  end

  defp merge_vars(%Email{template: nil}), do: nil
  defp merge_vars(%Email{template_vars: vars}) when map_size(vars) == 0, do: nil

  defp merge_vars(%Email{template_vars: vars}),
    do: Enum.map(vars, fn {name, content} -> %{name: name, content: content} end)

  defp template(%Email{template: nil}), do: %{}

  defp template(%Email{template: name, provider_options: options}) do
    %{template_name: name, template_content: Map.get(options, :template_content, [])}
  end

  defp handle_response(%Req.Response{status: status, body: results} = response)
       when status in 200..299 and is_list(results) do
    case Enum.reject(results, &(&1["status"] in @ok_statuses)) do
      [] ->
        {:ok, %Response{id: get_in(results, [Access.at(0), "_id"]), provider: provider(), raw: results}}

      failed ->
        message =
          Enum.map_join(
            failed,
            "; ",
            &"#{&1["email"]}: #{&1["status"]} (#{&1["reject_reason"] || "no reason"})"
          )

        {:error, HTTP.api_error(provider(), response, message)}
    end
  end

  defp handle_response(%Req.Response{body: body} = response) do
    {:error, HTTP.api_error(provider(), response, HTTP.error_message(body, ["message", "name"]))}
  end
end
