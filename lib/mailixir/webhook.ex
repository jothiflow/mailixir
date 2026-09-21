defmodule Mailixir.Webhook do
  @moduledoc """
  Turns provider webhook requests into `Mailixir.Event` structs, verifying
  the request signature where the provider supports one.

      # In a Phoenix controller (raw body captured by `Mailixir.Plug.RawBody`)
      def mailgun(conn, _params) do
        case Mailixir.Webhook.parse(Mailixir.Webhooks.Mailgun, conn.assigns.raw_body, conn.req_headers,
               signing_key: System.fetch_env!("MAILGUN_WEBHOOK_KEY")) do
          {:ok, events} ->
            Enum.each(events, &MyApp.Deliverability.record/1)
            send_resp(conn, 200, "")

          {:error, %Mailixir.Error{reason: :invalid_signature}} ->
            send_resp(conn, 401, "")

          {:error, _} ->
            send_resp(conn, 400, "")
        end
      end

  | Webhook module                      | Verification                                   |
  |-------------------------------------|------------------------------------------------|
  | `Mailixir.Webhooks.Mailgun`         | HMAC-SHA256 (`:signing_key`)                   |
  | `Mailixir.Webhooks.SendGrid`        | ECDSA (`:public_key`)                          |
  | `Mailixir.Webhooks.Resend`          | Svix HMAC-SHA256 (`:signing_secret`)           |
  | `Mailixir.Webhooks.Postmark`        | HTTP basic auth (`:basic_auth`)                |
  | `Mailixir.Webhooks.Mandrill`        | HMAC-SHA1 (`:webhook_key`, `:url`)             |
  | `Mailixir.Webhooks.Mailjet`         | none offered by the provider                   |
  | `Mailixir.Webhooks.Brevo`           | none offered by the provider                   |
  | `Mailixir.Webhooks.SES`             | SNS envelope; verify SNS signatures upstream   |

  Verification only runs when its config key is given, so unauthenticated
  parsing is possible but never silent: `verified?/2` tells you whether a
  config would verify.

  ## Writing a webhook module

      defmodule MyApp.Webhooks.Custom do
        use Mailixir.Webhook, provider: :custom

        @impl true
        def parse(decoded_body, _config), do: {:ok, [%Mailixir.Event{type: :delivered, provider: :custom}]}
      end

  `use Mailixir.Webhook` provides a JSON `decode/2` and a no-op `verify/4`,
  both overridable.
  """

  alias Mailixir.{Error, Event}

  @type headers :: [{String.t(), String.t()}] | %{String.t() => String.t()}
  @type config :: keyword()

  @callback provider() :: atom()

  @doc "Decodes the raw request body. Defaults to JSON."
  @callback decode(raw_body :: binary(), headers()) :: {:ok, term()} | {:error, Error.t()}

  @doc "Verifies the request. Receives the raw body, the decoded body, and lowercase headers."
  @callback verify(raw_body :: binary(), decoded :: term(), headers(), config()) :: :ok | {:error, Error.t()}

  @doc "Maps the decoded body to events."
  @callback parse(decoded :: term(), config()) :: {:ok, [Event.t()]} | {:error, Error.t()}

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote do
      @behaviour Mailixir.Webhook

      alias Mailixir.{Error, Event}

      import Mailixir.Webhook,
        only: [header: 2, unix: 1, iso8601: 1, event: 2, secure_compare: 2, invalid: 1, invalid: 2]

      @impl Mailixir.Webhook
      def provider, do: unquote(provider)

      @impl Mailixir.Webhook
      def decode(raw_body, _headers), do: Mailixir.Webhook.decode_json(raw_body, unquote(provider))

      @impl Mailixir.Webhook
      def verify(_raw_body, _decoded, _headers, _config), do: :ok

      defoverridable decode: 2, verify: 4
    end
  end

  @doc "Verifies, decodes and parses a webhook request."
  @spec parse(module(), binary(), headers(), config()) :: {:ok, [Event.t()]} | {:error, Error.t()}
  def parse(module, raw_body, headers, config \\ []) when is_binary(raw_body) do
    headers = normalize_headers(headers)

    with {:ok, decoded} <- module.decode(raw_body, headers),
         :ok <- module.verify(raw_body, decoded, headers, config) do
      module.parse(decoded, config)
    end
  end

  @doc false
  @spec decode_json(binary(), atom()) :: {:ok, term()} | {:error, Error.t()}
  def decode_json(raw_body, provider) do
    case JSON.decode(raw_body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, invalid(provider, "body is not valid JSON: #{inspect(reason)}")}
    end
  end

  @doc "Fetches a header value (case-insensitive name) from normalized headers."
  @spec header(headers(), String.t()) :: String.t() | nil
  def header(headers, name) do
    name = String.downcase(name)
    headers |> normalize_headers() |> Enum.find_value(fn {k, v} -> if k == name, do: v end)
  end

  @doc "Constant-time comparison of two binaries."
  @spec secure_compare(binary(), binary()) :: boolean()
  def secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  def secure_compare(_a, _b), do: false

  @doc "Converts a unix timestamp (integer, float, or numeric string; seconds or milliseconds) to `DateTime`."
  @spec unix(term()) :: DateTime.t() | nil
  def unix(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _} -> unix(number)
      :error -> nil
    end
  end

  def unix(value) when is_float(value), do: unix(trunc(value * 1000), :millisecond)
  def unix(value) when is_integer(value) and value > 100_000_000_000, do: unix(value, :millisecond)
  def unix(value) when is_integer(value), do: unix(value, :second)
  def unix(_value), do: nil

  defp unix(value, unit) do
    case DateTime.from_unix(value, unit) do
      {:ok, datetime} -> DateTime.truncate(datetime, :second)
      _ -> nil
    end
  end

  @doc "Parses an ISO 8601 / RFC 3339 timestamp, tolerating a space separator and missing zone (assumed UTC)."
  @spec iso8601(term()) :: DateTime.t() | nil
  def iso8601(value) when is_binary(value) do
    normalized = value |> String.replace(" ", "T", global: false)

    case DateTime.from_iso8601(normalized) do
      {:ok, datetime, _offset} ->
        DateTime.truncate(datetime, :second)

      _ ->
        case NaiveDateTime.from_iso8601(normalized) do
          {:ok, naive} -> naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)
          _ -> nil
        end
    end
  end

  def iso8601(_value), do: nil

  @doc "Builds an event; `fields` may include any `Mailixir.Event` key."
  @spec event(atom(), keyword()) :: Event.t()
  def event(provider, fields), do: struct!(Event, [provider: provider] ++ fields)

  @doc "Builds an `:invalid_payload` error."
  @spec invalid(atom(), String.t()) :: Error.t()
  def invalid(provider, message \\ "unexpected webhook payload") do
    Error.new(:invalid_payload, message, provider: provider)
  end

  @doc "Builds an `:invalid_signature` error."
  @spec invalid_signature(atom(), String.t()) :: Error.t()
  def invalid_signature(provider, message \\ "webhook signature verification failed") do
    Error.new(:invalid_signature, message, provider: provider)
  end

  defp normalize_headers(headers) when is_map(headers), do: headers |> Map.to_list() |> normalize_headers()

  defp normalize_headers(headers) when is_list(headers),
    do: Enum.map(headers, fn {k, v} -> {String.downcase(to_string(k)), v} end)
end
