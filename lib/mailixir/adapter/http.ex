defmodule Mailixir.Adapter.HTTP do
  @moduledoc """
  Thin layer over `Req` shared by the HTTP adapters.

  Every adapter honours a `:req_options` config key whose keyword list is merged
  last into the request — use it for timeouts, retries, proxies, or
  `plug: {Req.Test, MyStub}` in tests.
  """

  alias Mailixir.Error

  @doc """
  Performs the request and normalises transport failures into `Mailixir.Error`.

  Provider error responses (non-2xx) are returned as `{:ok, response}` — mapping
  their body to an error is provider-specific and left to the adapter.
  """
  @spec request(atom(), Mailixir.Adapter.config(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, Error.t()}
  def request(provider, config, req_opts) do
    req_opts
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.new()
    |> Req.request()
    |> case do
      {:ok, %Req.Response{} = response} ->
        {:ok, response}

      {:error, exception} ->
        {:error,
         Error.new(:transport, Exception.message(exception),
           provider: provider,
           details: exception
         )}
    end
  end

  @doc "Builds an `:api_error` from a non-2xx response."
  @spec api_error(atom(), Req.Response.t(), String.t()) :: Error.t()
  def api_error(provider, %Req.Response{status: status, body: body}, message) do
    Error.new(:api_error, "HTTP #{status}: #{message}",
      provider: provider,
      status: status,
      details: body
    )
  end

  @doc """
  Pulls a human-readable message out of a decoded error body, trying each
  key in turn, then falling back to inspecting the body.
  """
  @spec error_message(term(), [String.t()]) :: String.t()
  def error_message(body, keys) when is_map(body) do
    Enum.find_value(keys, fn key ->
      case Map.get(body, key) do
        message when is_binary(message) and message != "" -> message
        _ -> nil
      end
    end) || inspect(body)
  end

  def error_message(body, _keys) when is_binary(body) and body != "", do: body
  def error_message(body, _keys), do: inspect(body)

  @doc """
  Resolves a credential that may be static or fetched on demand — a string,
  a `{module, function, args}` tuple, or a zero-arity function. Fetchers may
  return the value directly or as `{:ok, value}` / `{:error, reason}`.

  Used for short-lived OAuth access tokens (Gmail, Microsoft Graph).
  """
  @spec resolve_credential(term(), atom(), atom()) :: {:ok, String.t()} | {:error, Error.t()}
  def resolve_credential(value, provider, key) do
    case value do
      binary when is_binary(binary) -> {:ok, binary}
      {m, f, a} when is_atom(m) and is_atom(f) and is_list(a) -> normalize_credential(apply(m, f, a), provider, key)
      fun when is_function(fun, 0) -> normalize_credential(fun.(), provider, key)
      other -> {:error, invalid_credential(provider, key, other)}
    end
  end

  defp normalize_credential({:ok, value}, _provider, _key) when is_binary(value), do: {:ok, value}
  defp normalize_credential(value, _provider, _key) when is_binary(value), do: {:ok, value}

  defp normalize_credential({:error, reason}, provider, key) do
    {:error,
     Error.new(:invalid_config, "fetching #{inspect(key)} failed: #{inspect(reason)}",
       provider: provider,
       details: reason
     )}
  end

  defp normalize_credential(other, provider, key), do: {:error, invalid_credential(provider, key, other)}

  defp invalid_credential(provider, key, value) do
    Error.new(
      :invalid_config,
      "#{inspect(key)} must be a string, {m, f, a} or a 0-arity function, got: #{inspect(value)}",
      provider: provider,
      details: value
    )
  end

  @doc "True for 2xx statuses."
  @spec success?(Req.Response.t()) :: boolean()
  def success?(%Req.Response{status: status}), do: status in 200..299

  @doc "Returns `nil` for empty lists and maps so optional fields are omitted; other values pass through."
  @spec presence(term()) :: term()
  def presence([]), do: nil
  def presence(map) when map_size(map) == 0, do: nil
  def presence(value), do: value

  @doc "Drops `nil` values so optional fields are omitted from JSON payloads."
  @spec compact(map()) :: map()
  def compact(map) when is_map(map),
    do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
end
