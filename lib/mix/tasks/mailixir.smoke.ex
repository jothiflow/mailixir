defmodule Mix.Tasks.Mailixir.Smoke do
  @shortdoc "Sends real test emails through every provider that has credentials in the environment"

  @moduledoc """
  Live smoke test: sends a minimal email and a full-featured one (attachment,
  inline image, tags, metadata, reply-to) through each configured provider and
  reports the outcome.

      MAILIXIR_SMOKE_FROM=you@yourdomain.com MAILIXIR_SMOKE_TO=inbox@example.com \\
      RESEND_API_KEY=re_… POSTMARK_SERVER_TOKEN=… mix mailixir.smoke

  Options:

    * `--adapter NAME` — only run these adapters (repeatable), e.g. `--adapter resend --adapter ses`
    * `--minimal` — send only the minimal email
    * `--from`, `--to` — override the environment variables

  Adapters are picked up when their variables are present:

  | Adapter          | Environment variables                                                         |
  |------------------|-------------------------------------------------------------------------------|
  | brevo            | `BREVO_API_KEY`                                                               |
  | gmail            | `GMAIL_ACCESS_TOKEN`                                                          |
  | mailgun          | `MAILGUN_API_KEY`, `MAILGUN_DOMAIN`, optional `MAILGUN_BASE_URL`              |
  | mailjet          | `MAILJET_API_KEY`, `MAILJET_SECRET_KEY`                                       |
  | mailpace         | `MAILPACE_API_KEY`                                                            |
  | mailtrap         | `MAILTRAP_API_KEY`, optional `MAILTRAP_INBOX_ID`                              |
  | mandrill         | `MANDRILL_API_KEY`                                                            |
  | microsoft_graph  | `MSGRAPH_ACCESS_TOKEN`, optional `MSGRAPH_USER_ID`                            |
  | postal           | `POSTAL_API_KEY`, `POSTAL_BASE_URL`                                           |
  | postmark         | `POSTMARK_SERVER_TOKEN`, optional `POSTMARK_MESSAGE_STREAM`                   |
  | resend           | `RESEND_API_KEY`                                                              |
  | scaleway         | `SCW_SECRET_KEY`, `SCW_PROJECT_ID`, optional `SCW_REGION`                     |
  | sendgrid         | `SENDGRID_API_KEY`                                                            |
  | sendmail         | `SENDMAIL_PATH` (set to enable; e.g. `/usr/sbin/sendmail`)                    |
  | ses              | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, optional `AWS_SESSION_TOKEN` |
  | smtp             | `SMTP_RELAY`, optional `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_SSL`, `SMTP_TLS` |
  | smtp2go          | `SMTP2GO_API_KEY`                                                             |
  | sparkpost        | `SPARKPOST_API_KEY`                                                           |

  Exit status is non-zero when any send fails.
  """

  use Mix.Task

  alias Mailixir.{Adapters, Attachment, Email}

  @providers [
    brevo: {Adapters.Brevo, [api_key: "BREVO_API_KEY"], []},
    gmail: {Adapters.Gmail, [access_token: "GMAIL_ACCESS_TOKEN"], []},
    mailgun: {Adapters.Mailgun, [api_key: "MAILGUN_API_KEY", domain: "MAILGUN_DOMAIN"], [base_url: "MAILGUN_BASE_URL"]},
    mailjet: {Adapters.Mailjet, [api_key: "MAILJET_API_KEY", secret_key: "MAILJET_SECRET_KEY"], []},
    mailpace: {Adapters.MailPace, [api_key: "MAILPACE_API_KEY"], []},
    mailtrap: {Adapters.Mailtrap, [api_key: "MAILTRAP_API_KEY"], [inbox_id: "MAILTRAP_INBOX_ID"]},
    mandrill: {Adapters.Mandrill, [api_key: "MANDRILL_API_KEY"], []},
    microsoft_graph: {Adapters.MicrosoftGraph, [access_token: "MSGRAPH_ACCESS_TOKEN"], [user_id: "MSGRAPH_USER_ID"]},
    postal: {Adapters.Postal, [api_key: "POSTAL_API_KEY", base_url: "POSTAL_BASE_URL"], []},
    postmark: {Adapters.Postmark, [api_key: "POSTMARK_SERVER_TOKEN"], [message_stream: "POSTMARK_MESSAGE_STREAM"]},
    resend: {Adapters.Resend, [api_key: "RESEND_API_KEY"], []},
    scaleway: {Adapters.Scaleway, [secret_key: "SCW_SECRET_KEY", project_id: "SCW_PROJECT_ID"], [region: "SCW_REGION"]},
    sendgrid: {Adapters.SendGrid, [api_key: "SENDGRID_API_KEY"], []},
    sendmail: {Adapters.Sendmail, [path: "SENDMAIL_PATH"], []},
    ses:
      {Adapters.SES,
       [access_key_id: "AWS_ACCESS_KEY_ID", secret_access_key: "AWS_SECRET_ACCESS_KEY", region: "AWS_REGION"],
       [session_token: "AWS_SESSION_TOKEN"]},
    smtp:
      {Adapters.SMTP, [relay: "SMTP_RELAY"],
       [port: "SMTP_PORT", username: "SMTP_USERNAME", password: "SMTP_PASSWORD", ssl: "SMTP_SSL", tls: "SMTP_TLS"]},
    smtp2go: {Adapters.SMTP2GO, [api_key: "SMTP2GO_API_KEY"], []},
    sparkpost: {Adapters.SparkPost, [api_key: "SPARKPOST_API_KEY"], []}
  ]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [adapter: :keep, minimal: :boolean, from: :string, to: :string])
    Mix.Task.run("app.start")

    from = opts[:from] || System.get_env("MAILIXIR_SMOKE_FROM") || Mix.raise("set MAILIXIR_SMOKE_FROM or pass --from")
    to = opts[:to] || System.get_env("MAILIXIR_SMOKE_TO") || Mix.raise("set MAILIXIR_SMOKE_TO or pass --to")
    only = opts |> Keyword.get_values(:adapter) |> Enum.map(&String.to_atom/1)

    configured =
      for {name, {adapter, required, optional}} <- @providers,
          only == [] or name in only,
          config = build_config(adapter, required, optional),
          do: {name, config}

    if configured == [], do: Mix.raise("no adapter has credentials in the environment; see `mix help mailixir.smoke`")

    Mix.shell().info("Sending from #{from} to #{to} via: #{Enum.map_join(configured, ", ", &elem(&1, 0))}\n")

    emails =
      if opts[:minimal],
        do: [{"minimal", minimal(from, to)}],
        else: [{"minimal", minimal(from, to)}, {"full", full(from, to)}]

    results =
      for {name, config} <- configured, {label, email} <- emails do
        {name, label, Mailixir.deliver(email, config)}
      end

    Enum.each(results, &report/1)
    failures = Enum.count(results, &match?({_, _, {:error, _}}, &1))
    Mix.shell().info("\n#{length(results) - failures}/#{length(results)} sends succeeded")
    if failures > 0, do: exit({:shutdown, 1})
  end

  defp build_config(adapter, required, optional) do
    required_values = Enum.map(required, fn {key, var} -> {key, System.get_env(var)} end)

    if Enum.all?(required_values, fn {_, v} -> v not in [nil, ""] end) do
      optional_values =
        for {key, var} <- optional, value = System.get_env(var), value != "", do: {key, coerce(key, value)}

      [adapter: adapter] ++ required_values ++ optional_values
    end
  end

  defp coerce(key, value) when key in [:port, :inbox_id], do: String.to_integer(value)
  defp coerce(:ssl, value), do: value in ["true", "1"]
  defp coerce(:tls, value), do: String.to_atom(value)
  defp coerce(_key, value), do: value

  defp minimal(from, to) do
    Email.new(
      from: from,
      to: to,
      subject: "[mailixir smoke] minimal",
      text_body: "Minimal text-only email from mix mailixir.smoke."
    )
  end

  defp full(from, to) do
    Email.new(
      from: {"Mailixir Smoke", from},
      to: to,
      reply_to: from,
      subject: "[mailixir smoke] full — attachments, inline image, tags & métadata",
      text_body:
        "Full email from mix mailixir.smoke.\n\nIt has a text part, an HTML part, one attachment and one inline image.",
      html_body:
        ~s(<p>Full email from <strong>mix mailixir.smoke</strong>.</p><p><img src="cid:pixel" alt="inline pixel"></p>),
      headers: %{"X-Mailixir-Smoke" => "1"},
      attachments: [
        Attachment.new({"hello.txt", "Hello from Mailixir\n"}, content_type: "text/plain"),
        Attachment.new({"pixel.png", pixel()}, type: :inline, content_id: "pixel")
      ],
      tags: ["smoke"],
      metadata: %{"run_id" => Integer.to_string(System.os_time(:second))}
    )
  end

  # 1x1 transparent PNG
  defp pixel do
    Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
  end

  defp report({name, label, {:ok, response}}) do
    Mix.shell().info("  ok    #{pad(name)} #{pad(label, 8)} id=#{inspect(response.id)}")
  end

  defp report({name, label, {:error, error}}) do
    Mix.shell().error("  FAIL  #{pad(name)} #{pad(label, 8)} #{error.reason}: #{error.message}")
    if error.details, do: Mix.shell().info("        #{inspect(error.details, limit: 20, printable_limit: 300)}")
  end

  defp pad(value, width \\ 16), do: String.pad_trailing(to_string(value), width)
end
