defmodule Mailixir do
  @moduledoc """
  One `Mailixir.Email`, one `deliver/2`, many providers.

      email =
        Mailixir.Email.new(
          from: {"Acme", "no-reply@acme.com"},
          to: "jane@example.com",
          subject: "Welcome",
          html_body: "<p>Hello!</p>"
        )

      Mailixir.deliver(email, adapter: Mailixir.Adapters.Resend, api_key: "re_...")
      #=> {:ok, %Mailixir.Response{id: "49a3...", provider: :resend}}

  Most applications define a mailer module instead of passing config around —
  see `Mailixir.Mailer`.

  ## Adapters

  HTTP APIs: `Mailixir.Adapters.SES`, `Mailixir.Adapters.Brevo`, `Mailixir.Adapters.Gmail`,
  `Mailixir.Adapters.Mandrill`, `Mailixir.Adapters.Mailgun`, `Mailixir.Adapters.Mailjet`,
  `Mailixir.Adapters.MailPace`, `Mailixir.Adapters.Mailtrap`, `Mailixir.Adapters.MicrosoftGraph`,
  `Mailixir.Adapters.Postal`, `Mailixir.Adapters.Postmark`, `Mailixir.Adapters.Resend`,
  `Mailixir.Adapters.Scaleway`, `Mailixir.Adapters.SendGrid`, `Mailixir.Adapters.SMTP2GO`,
  `Mailixir.Adapters.SparkPost`.

  Transports: `Mailixir.Adapters.SMTP`, `Mailixir.Adapters.Sendmail`.

  Composition and development: `Mailixir.Adapters.Fallback`, `Mailixir.Adapters.Local`,
  `Mailixir.Adapters.Logger`, `Mailixir.Adapters.Test`.

  Each adapter's moduledoc lists its required configuration and how the
  common fields map onto that provider.

  ## Configuration values

  Any config value may be `{:system, "ENV_VAR"}` or `{:system, "ENV_VAR", default}`;
  it is read from the environment at delivery time.

  ## Telemetry

  Every delivery is wrapped in a `:telemetry.span/3`:

    * `[:mailixir, :deliver, :start]` — measurements `%{system_time}`,
      metadata `%{email, adapter, provider, mailer}`
    * `[:mailixir, :deliver, :stop]` — measurements `%{duration}`,
      metadata adds `:result` (`{:ok, response}` or `{:error, error}`)
    * `[:mailixir, :deliver, :exception]` — when the adapter raises

  `deliver_many/2` emits the same under `[:mailixir, :deliver_many, ...]` with
  `:emails` and `:count` in place of `:email`.

  Configuration is deliberately excluded from metadata so credentials never
  reach log handlers.
  """

  alias Mailixir.{Email, Error, Response}

  @type config :: keyword()

  @typedoc """
  Options for `deliver/3` and `deliver_many/3`:

    * `:mailer` — the mailer module, forwarded as telemetry metadata
    * `:telemetry_metadata` — extra metadata merged into every event
  """
  @type opts :: [mailer: module(), telemetry_metadata: map()]

  @doc """
  Delivers `email` using the adapter in `config[:adapter]`.

  Runs, in order: config resolution, `c:Mailixir.Adapter.validate_config/1`,
  `Mailixir.Email.validate/1`, then `c:Mailixir.Adapter.deliver/2`.
  """
  @spec deliver(Email.t(), config(), opts()) :: {:ok, Response.t()} | {:error, Error.t()}
  def deliver(%Email{} = email, config, opts \\ []) when is_list(config) do
    with {:ok, config, adapter} <- prepare(config),
         {:ok, email} <- Email.validate(email) do
      metadata = metadata(opts, adapter, %{email: email})

      :telemetry.span([:mailixir, :deliver], metadata, fn ->
        result = adapter.deliver(email, config)
        {result, Map.put(metadata, :result, result)}
      end)
    end
  end

  @doc "Same as `deliver/3` but returns the response or raises the `Mailixir.Error`."
  @spec deliver!(Email.t(), config(), opts()) :: Response.t()
  def deliver!(email, config, opts \\ []) do
    case deliver(email, config, opts) do
      {:ok, response} -> response
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc """
  Delivers several emails with one adapter.

  All emails are validated before anything is sent. Adapters that implement
  `c:Mailixir.Adapter.deliver_many/2` send them in a single provider request;
  otherwise each email is delivered in turn. Returns `{:ok, responses}` only
  when every email succeeded; otherwise a `:batch_failure` error whose
  `:details` lists each email's `{:ok, _}` / `{:error, _}` result in order.
  """
  @spec deliver_many([Email.t()], config(), opts()) :: {:ok, [Response.t()]} | {:error, Error.t()}
  def deliver_many(emails, config, opts \\ []) when is_list(emails) and is_list(config) do
    with {:ok, config, adapter} <- prepare(config),
         {:ok, emails} <- validate_all(emails) do
      metadata = metadata(opts, adapter, %{emails: emails, count: length(emails)})

      :telemetry.span([:mailixir, :deliver_many], metadata, fn ->
        result = run_deliver_many(adapter, emails, config)
        {result, Map.put(metadata, :result, result)}
      end)
    end
  end

  @doc "Same as `deliver_many/3` but returns the responses or raises the `Mailixir.Error`."
  @spec deliver_many!([Email.t()], config(), opts()) :: [Response.t()]
  def deliver_many!(emails, config, opts \\ []) do
    case deliver_many(emails, config, opts) do
      {:ok, responses} -> responses
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc """
  Replaces `{:system, var}` / `{:system, var, default}` values with their
  environment values. Public so custom mailers can reuse it.
  """
  @spec resolve_config(config()) :: {:ok, config()} | {:error, Error.t()}
  def resolve_config(config) do
    Enum.reduce_while(config, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case resolve_value(value) do
        {:ok, resolved} -> {:cont, {:ok, [{key, resolved} | acc]}}
        {:error, var} -> {:halt, {:error, missing_env(key, var)}}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      error -> error
    end
  end

  defp prepare(config) do
    with {:ok, config} <- resolve_config(config),
         {:ok, adapter} <- fetch_adapter(config),
         :ok <- adapter.validate_config(config) do
      {:ok, config, adapter}
    end
  end

  defp validate_all(emails) do
    emails
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {email, index}, {:ok, acc} ->
      case Email.validate(email) do
        {:ok, email} ->
          {:cont, {:ok, [email | acc]}}

        {:error, %Error{} = error} ->
          {:halt, {:error, %{error | message: "email at index #{index}: #{error.message}"}}}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      error -> error
    end
  end

  defp run_deliver_many(adapter, emails, config) do
    if function_exported?(adapter, :deliver_many, 2),
      do: adapter.deliver_many(emails, config),
      else: deliver_each(adapter, emails, config)
  end

  defp deliver_each(adapter, emails, config) do
    results = Enum.map(emails, &adapter.deliver(&1, config))

    case Enum.count(results, &match?({:error, _}, &1)) do
      0 ->
        {:ok, Enum.map(results, fn {:ok, response} -> response end)}

      failed ->
        {:error,
         Error.new(:batch_failure, "#{failed} of #{length(results)} emails failed",
           provider: adapter.provider(),
           details: results
         )}
    end
  end

  defp metadata(opts, adapter, extra) do
    opts
    |> Keyword.get(:telemetry_metadata, %{})
    |> Map.merge(%{adapter: adapter, provider: adapter.provider(), mailer: Keyword.get(opts, :mailer)})
    |> Map.merge(extra)
  end

  defp resolve_value({:system, var}) when is_binary(var) do
    case System.get_env(var) do
      nil -> {:error, var}
      value -> {:ok, value}
    end
  end

  defp resolve_value({:system, var, default}) when is_binary(var), do: {:ok, System.get_env(var, default)}
  defp resolve_value(value), do: {:ok, value}

  defp missing_env(key, var) do
    Error.new(:invalid_config, "config #{inspect(key)} reads environment variable #{var}, which is not set",
      details: {key, var}
    )
  end

  defp fetch_adapter(config) do
    case Keyword.get(config, :adapter) do
      nil ->
        {:error, Error.new(:invalid_config, "config is missing :adapter")}

      adapter when is_atom(adapter) ->
        if Code.ensure_loaded?(adapter) and function_exported?(adapter, :deliver, 2) do
          {:ok, adapter}
        else
          {:error, Error.new(:invalid_config, "#{inspect(adapter)} is not a Mailixir.Adapter", details: adapter)}
        end

      other ->
        {:error, Error.new(:invalid_config, "adapter must be a module, got: #{inspect(other)}", details: other)}
    end
  end
end
