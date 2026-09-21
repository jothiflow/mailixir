defmodule Mailixir.Adapters.SMTP do
  @moduledoc """
  Delivers over SMTP using [gen_smtp](https://hex.pm/packages/gen_smtp) as the
  transport. The message itself is built by `Mailixir.MIME`.

  Add the optional dependency:

      {:gen_smtp, "~> 1.2"}

  ## Configuration

    * `:relay` — required, SMTP server hostname
    * `:port` — defaults to 25 (or 465 with `ssl: true`)
    * `:username`, `:password`
    * `:auth` — `:always`, `:never` or `:if_available` (default)
    * `:tls` — STARTTLS: `:always`, `:never` or `:if_available` (default)
    * `:ssl` — implicit TLS from the first byte (port 465), default `false`
    * `:tls_options` — `:ssl` client options, e.g. `[verify: :verify_peer, cacerts: :public_key.cacerts_get()]`
    * `:hostname` — name sent in EHLO, defaults to the machine FQDN
    * `:retries` — connection retries, default 1
    * `:timeout` — socket timeout in ms
    * `:no_mx_lookups` — connect to `:relay` directly instead of resolving MX records

  The response `:id` is the generated `Message-ID`; `:raw` holds the server's
  receipt line.
  """

  use Mailixir.Adapter, provider: :smtp, required_config: [:relay]

  alias Mailixir.{Email, Error, MIME, Response}

  @client_options ~w(relay port username password auth tls ssl tls_options hostname retries timeout no_mx_lookups)a

  @impl true
  def validate_config(config) do
    if Code.ensure_loaded?(:gen_smtp_client) do
      Mailixir.Adapter.validate_required(config, [:relay], provider())
    else
      {:error,
       Error.new(:invalid_config, ~s(Mailixir.Adapters.SMTP requires {:gen_smtp, "~> 1.2"} in your deps),
         provider: provider()
       )}
    end
  end

  @impl true
  def deliver(%Email{} = email, config) do
    message_id = MIME.message_id(email)
    {from, recipients} = MIME.envelope(email)
    raw = MIME.encode(email, message_id: message_id)

    case :gen_smtp_client.send_blocking({from, recipients, raw}, client_options(config)) do
      receipt when is_binary(receipt) ->
        {:ok, %Response{id: message_id, provider: provider(), raw: String.trim(receipt)}}

      {:error, _type, {:network_failure, host, {:error, reason}} = details} ->
        {:error,
         Error.new(:transport, "#{inspect(reason)} connecting to #{host}", provider: provider(), details: details)}

      {:error, _type, {kind, host, reason} = details} ->
        {:error,
         Error.new(:api_error, "#{kind} on #{host}: #{format_reason(reason)}", provider: provider(), details: details)}

      {:error, reason} ->
        {:error,
         Error.new(:invalid_config, "gen_smtp rejected options: #{inspect(reason)}",
           provider: provider(),
           details: reason
         )}
    end
  end

  @doc false
  @spec client_options(Mailixir.Adapter.config()) :: keyword()
  def client_options(config) do
    config
    |> Keyword.take(@client_options)
    |> Keyword.put_new_lazy(:port, fn -> if config[:ssl], do: 465, else: 25 end)
  end

  defp format_reason(reason) when is_binary(reason), do: String.trim(reason)
  defp format_reason(reason) when is_list(reason), do: Enum.map_join(reason, " ", &format_reason/1)
  defp format_reason(reason), do: inspect(reason)
end
