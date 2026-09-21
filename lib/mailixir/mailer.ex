defmodule Mailixir.Mailer do
  @moduledoc """
  Defines an application mailer bound to OTP application config.

      defmodule MyApp.Mailer do
        use Mailixir.Mailer, otp_app: :my_app
      end

      # config/runtime.exs
      config :my_app, MyApp.Mailer,
        adapter: Mailixir.Adapters.Brevo,
        api_key: {:system, "BREVO_API_KEY"}

      MyApp.Mailer.deliver(email)
      MyApp.Mailer.deliver(email, adapter: Mailixir.Adapters.Test)   # per-call override

  Static options given to `use` act as defaults beneath the application
  environment, so a mailer can also be fully configured inline:

      use Mailixir.Mailer, adapter: Mailixir.Adapters.SES, region: "eu-west-1"

  Resolution order (later wins): `use` options → `config :otp_app, Mailer` → call-site overrides.
  """

  @doc "Returns the merged configuration; useful for inspection in tests."
  @callback config(overrides :: Mailixir.config()) :: Mailixir.config()

  @callback deliver(Mailixir.Email.t(), overrides :: Mailixir.config()) ::
              {:ok, Mailixir.Response.t()} | {:error, Mailixir.Error.t()}

  @callback deliver!(Mailixir.Email.t(), overrides :: Mailixir.config()) :: Mailixir.Response.t()

  @callback deliver_many([Mailixir.Email.t()], overrides :: Mailixir.config()) ::
              {:ok, [Mailixir.Response.t()]} | {:error, Mailixir.Error.t()}

  @callback deliver_many!([Mailixir.Email.t()], overrides :: Mailixir.config()) :: [Mailixir.Response.t()]

  defmacro __using__(opts) do
    {otp_app, static_config} = Keyword.pop(opts, :otp_app)

    quote do
      @behaviour Mailixir.Mailer

      @impl Mailixir.Mailer
      def config(overrides \\ []) do
        unquote(static_config)
        |> Keyword.merge(Mailixir.Mailer.app_config(unquote(otp_app), __MODULE__))
        |> Keyword.merge(overrides)
      end

      @impl Mailixir.Mailer
      def deliver(email, overrides \\ []), do: Mailixir.deliver(email, config(overrides), mailer: __MODULE__)

      @impl Mailixir.Mailer
      def deliver!(email, overrides \\ []), do: Mailixir.deliver!(email, config(overrides), mailer: __MODULE__)

      @impl Mailixir.Mailer
      def deliver_many(emails, overrides \\ []),
        do: Mailixir.deliver_many(emails, config(overrides), mailer: __MODULE__)

      @impl Mailixir.Mailer
      def deliver_many!(emails, overrides \\ []),
        do: Mailixir.deliver_many!(emails, config(overrides), mailer: __MODULE__)
    end
  end

  @doc false
  @spec app_config(atom() | nil, module()) :: keyword()
  def app_config(nil, _mailer), do: []
  def app_config(otp_app, mailer), do: Application.get_env(otp_app, mailer, [])
end
