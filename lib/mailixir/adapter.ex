defmodule Mailixir.Adapter do
  @moduledoc """
  Behaviour every delivery adapter implements.

  Adapters receive an already-validated `Mailixir.Email` and the resolved
  configuration keyword list (all `{:system, "VAR"}` tuples replaced), and must
  return a `Mailixir.Response` or a `Mailixir.Error`.

      defmodule MyApp.CustomAdapter do
        use Mailixir.Adapter, provider: :custom, required_config: [:api_key]

        @impl true
        def deliver(email, config), do: ...
      end

  `use Mailixir.Adapter` defines `provider/0` and a default `validate_config/1`
  that checks the listed keys are present and non-nil.
  """

  alias Mailixir.{Email, Error, Response}

  @type config :: keyword()

  @doc "Sends the email. Only called after `validate_config/1` and `Mailixir.Email.validate/1` succeed."
  @callback deliver(Email.t(), config()) :: {:ok, Response.t()} | {:error, Error.t()}

  @doc "Checks the configuration before any request is made."
  @callback validate_config(config()) :: :ok | {:error, Error.t()}

  @doc "Short atom identifying the provider, used in `Mailixir.Response` and `Mailixir.Error`."
  @callback provider() :: atom()

  @doc """
  Sends several emails in one provider round-trip. Optional: when not
  implemented, `Mailixir.deliver_many/2` calls `deliver/2` for each email.
  Every email has already been validated.
  """
  @callback deliver_many([Email.t()], config()) :: {:ok, [Response.t()]} | {:error, Error.t()}

  @optional_callbacks deliver_many: 2

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)
    required = Keyword.get(opts, :required_config, [])

    quote do
      @behaviour Mailixir.Adapter

      @impl Mailixir.Adapter
      def provider, do: unquote(provider)

      @impl Mailixir.Adapter
      def validate_config(config) do
        Mailixir.Adapter.validate_required(config, unquote(required), unquote(provider))
      end

      defoverridable validate_config: 1
    end
  end

  @doc "Returns `:ok` when every key in `required` is present and non-nil in `config`."
  @spec validate_required(config(), [atom()], atom()) :: :ok | {:error, Error.t()}
  def validate_required(config, required, provider) do
    case Enum.filter(required, &is_nil(Keyword.get(config, &1))) do
      [] ->
        :ok

      missing ->
        {:error,
         Error.new(
           :invalid_config,
           "missing required config: #{Enum.map_join(missing, ", ", &inspect/1)}",
           provider: provider,
           details: missing
         )}
    end
  end
end
