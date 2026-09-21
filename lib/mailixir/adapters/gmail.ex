defmodule Mailixir.Adapters.Gmail do
  @moduledoc """
  Adapter for the [Gmail API](https://developers.google.com/gmail/api) —
  `POST /gmail/v1/users/{user}/messages/send` with the message built by `Mailixir.MIME`.

  ## Configuration

    * `:access_token` — required. An OAuth 2.0 access token with the
      `https://www.googleapis.com/auth/gmail.send` scope, given as a string,
      `{module, function, args}` or a zero-arity function so an expiring token
      can be fetched per delivery (e.g. `{Goth, :fetch!, [MyApp.Goth]}` — see
      `Mailixir.Adapter.HTTP.resolve_credential/3`)
    * `:user_id` — defaults to `"me"`
    * `:base_url` — defaults to `https://gmail.googleapis.com`
    * `:req_options` — extra `Req` options

  `tags`, `metadata` and `template` have no Gmail equivalent and are ignored.

  ## Provider options

    * `:thread_id` — reply within an existing thread
  """

  use Mailixir.Adapter, provider: :gmail, required_config: [:access_token]

  alias Mailixir.Adapter.HTTP
  alias Mailixir.{Email, MIME, Response}

  @default_base_url "https://gmail.googleapis.com"

  @impl true
  def deliver(%Email{} = email, config) do
    with {:ok, token} <- HTTP.resolve_credential(config[:access_token], provider(), :access_token),
         {:ok, response} <- HTTP.request(provider(), config, request_options(email, config, token)) do
      handle_response(response)
    end
  end

  defp request_options(email, config, token) do
    [
      method: :post,
      base_url: Keyword.get(config, :base_url, @default_base_url),
      url: "/gmail/v1/users/#{Keyword.get(config, :user_id, "me")}/messages/send",
      auth: {:bearer, token},
      json: payload(email)
    ]
  end

  @doc false
  @spec payload(Email.t()) :: map()
  def payload(%Email{} = email) do
    HTTP.compact(%{
      raw: email |> MIME.encode() |> Base.url_encode64(padding: false),
      threadId: email.provider_options[:thread_id]
    })
  end

  defp handle_response(%Req.Response{status: status, body: %{"id" => id} = body}) when status in 200..299 do
    {:ok, %Response{id: id, provider: provider(), raw: body}}
  end

  defp handle_response(%Req.Response{body: %{"error" => %{"message" => message}}} = response) do
    {:error, HTTP.api_error(provider(), response, message)}
  end

  defp handle_response(%Req.Response{body: body} = response) do
    {:error, HTTP.api_error(provider(), response, HTTP.error_message(body, ["message"]))}
  end
end
