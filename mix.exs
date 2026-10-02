defmodule Mailixir.MixProject do
  use Mix.Project

  @version "0.3.1"
  @source_url "https://github.com/jothiflow/mailixir"

  def project do
    [
      app: :mailixir,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      description: description(),
      package: package(),
      docs: docs(),
      dialyzer: [plt_add_apps: [:ex_unit, :mix]],
      name: "Mailixir",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Mailixir.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:mime, "~> 2.0"},
      {:telemetry, "~> 1.0"},
      {:plug, "~> 1.14", optional: true},
      {:gen_smtp, "~> 1.2", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Transactional email for Elixir: one Email struct, one deliver/2, adapters for SES, Brevo, Facteur, Gmail, " <>
      "Mailgun, Mailjet, Mandrill, Postmark, Resend, SendGrid, SparkPost, SMTP and more, webhook parsing, failover, dev mailbox."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        Core: [
          Mailixir,
          Mailixir.Email,
          Mailixir.Mailer,
          Mailixir.Attachment,
          Mailixir.Response,
          Mailixir.Error
        ],
        Adapters: ~r/Mailixir.Adapters.*/
      ]
    ]
  end
end
