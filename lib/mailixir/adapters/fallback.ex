defmodule Mailixir.Adapters.Fallback do
  @moduledoc """
  Fails over across providers: tries each configured adapter in order and
  moves to the next when the failure looks like an outage rather than a
  problem with the email itself.

      config :my_app, MyApp.Mailer,
        adapter: Mailixir.Adapters.Fallback,
        adapters: [
          [adapter: Mailixir.Adapters.SES, region: "eu-west-1", access_key_id: ..., secret_access_key: ...],
          [adapter: Mailixir.Adapters.Postmark, api_key: {:system, "POSTMARK_TOKEN"}]
        ]

  ## Configuration

    * `:adapters` — required, a non-empty list of adapter configs (each with its
      own `:adapter` key; `{:system, ...}` values are resolved per attempt)
    * `:failover_on` — `(Mailixir.Error.t() -> boolean())` deciding whether an
      error should trigger the next adapter. The default is
      `Mailixir.Error.not_accepted?/1`: a connection-phase failure, 429, or
      503. A timeout or any other 5xx is returned as-is, because the provider
      may already have accepted the message and the next one cannot
      deduplicate it. Other 4xx errors are returned immediately, since the
      next provider would reject the same email.

  ## Telemetry

  `[:mailixir, :fallback, :failover]` is emitted each time an adapter is
  skipped, with measurements `%{attempt: n}` and metadata
  `%{adapter, provider, error, email}`.

  The response carries the provider that actually delivered. When every
  adapter fails, the error has `provider: :fallback` and `:details` lists
  `{adapter, error}` per attempt.
  """

  use Mailixir.Adapter, provider: :fallback

  alias Mailixir.{Email, Error, Response}

  @impl true
  def validate_config(config) do
    with {:ok, configs} <- adapter_configs(config) do
      Enum.find_value(configs, :ok, &validation_error/1)
    end
  end

  defp validation_error({adapter, adapter_config}) do
    case adapter.validate_config(adapter_config) do
      :ok -> nil
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def deliver(%Email{} = email, config) do
    with {:ok, configs} <- adapter_configs(config) do
      failover? = Keyword.get(config, :failover_on, &failover?/1)
      attempt(configs, email, failover?, 1, [])
    end
  end

  @doc """
  Default failover policy.

  Delegates to `Mailixir.Error.not_accepted?/1`.
  """
  @spec failover?(Error.t()) :: boolean()
  def failover?(%Error{} = error), do: Error.not_accepted?(error)

  defp attempt([{adapter, adapter_config}], email, _failover?, n, attempts) do
    case adapter.deliver(email, adapter_config) do
      {:ok, %Response{} = response} -> {:ok, response}
      {:error, %Error{} = error} -> {:error, exhausted(error, n, Enum.reverse([{adapter, error} | attempts]))}
    end
  end

  defp attempt([{adapter, adapter_config} | rest], email, failover?, n, attempts) do
    case adapter.deliver(email, adapter_config) do
      {:ok, %Response{} = response} ->
        {:ok, response}

      {:error, %Error{} = error} ->
        if failover?.(error) do
          :telemetry.execute(
            [:mailixir, :fallback, :failover],
            %{attempt: n},
            %{adapter: adapter, provider: adapter.provider(), error: error, email: email}
          )

          attempt(rest, email, failover?, n + 1, [{adapter, error} | attempts])
        else
          {:error, error}
        end
    end
  end

  defp exhausted(last, count, attempts) do
    Error.new(last.reason, "all #{count} adapters failed; last: #{Exception.message(last)}",
      provider: provider(),
      status: last.status,
      details: attempts
    )
  end

  defp adapter_configs(config) do
    case Keyword.get(config, :adapters) do
      [_ | _] = configs ->
        collect(configs, [])

      _ ->
        {:error,
         Error.new(:invalid_config, ":adapters must be a non-empty list of adapter configs", provider: provider())}
    end
  end

  defp collect([], acc), do: {:ok, Enum.reverse(acc)}

  defp collect([adapter_config | rest], acc) do
    case resolve(adapter_config) do
      {:ok, pair} -> collect(rest, [pair | acc])
      {:error, error} -> {:error, error}
    end
  end

  defp resolve(adapter_config) when is_list(adapter_config) do
    with {:ok, resolved} <- Mailixir.resolve_config(adapter_config),
         {:ok, adapter} <- fetch_adapter(resolved) do
      {:ok, {adapter, resolved}}
    end
  end

  defp resolve(other) do
    {:error,
     Error.new(:invalid_config, "expected an adapter config keyword list, got: #{inspect(other)}", provider: provider())}
  end

  defp fetch_adapter(config) do
    adapter = Keyword.get(config, :adapter)

    cond do
      is_nil(adapter) or not is_atom(adapter) ->
        {:error, Error.new(:invalid_config, "each entry in :adapters needs an :adapter module", provider: provider())}

      Code.ensure_loaded?(adapter) and function_exported?(adapter, :deliver, 2) ->
        {:ok, adapter}

      true ->
        {:error, Error.new(:invalid_config, "#{inspect(adapter)} is not a Mailixir.Adapter", provider: provider())}
    end
  end
end
