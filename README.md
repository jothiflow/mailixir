# Mailixir

[![CI](https://github.com/jothiflow/mailixir/actions/workflows/ci.yml/badge.svg)](https://github.com/jothiflow/mailixir/actions/workflows/ci.yml)

Transactional email for Elixir: one `Mailixir.Email`, one `deliver/2`,
twenty-one adapters, webhook parsing back into one `Mailixir.Event`, and a
dev mailbox — with `req` as the only required runtime dependency.

```elixir
import Mailixir.Email

new()
|> from({"Acme", "no-reply@acme.com"})
|> to(user)                                   # any struct deriving Mailixir.Recipient
|> subject("Your invoice")
|> html_body(~s(<p>Attached.</p><img src="cid:logo">))
|> attachment(Mailixir.Attachment.new("/tmp/invoice.pdf"))
|> attachment(Mailixir.Attachment.new("priv/logo.png", type: :inline, content_id: "logo"))
|> tag("billing")
|> metadata("invoice_id", "inv_123")
|> MyApp.Mailer.deliver()
#=> {:ok, %Mailixir.Response{id: "…", provider: :postmark}}
```

## Adapters

| Provider | Adapter | Required config | `deliver_many` batch | Webhook parser |
|---|---|---|---|---|
| Amazon SES v2 | `Mailixir.Adapters.SES` | `:access_key_id`, `:secret_access_key`, `:region` | | `Mailixir.Webhooks.SES` |
| Brevo | `Mailixir.Adapters.Brevo` | `:api_key` | | `Mailixir.Webhooks.Brevo` |
| Facteur (self-hosted) | `Mailixir.Adapters.Facteur` | `:api_key`, `:base_url` | | `Mailixir.Webhooks.Facteur` |
| Gmail API | `Mailixir.Adapters.Gmail` | `:access_token` | | |
| Mailchimp Transactional (Mandrill) | `Mailixir.Adapters.Mandrill` | `:api_key` | | `Mailixir.Webhooks.Mandrill` |
| Mailgun | `Mailixir.Adapters.Mailgun` | `:api_key`, `:domain` | | `Mailixir.Webhooks.Mailgun` |
| Mailjet | `Mailixir.Adapters.Mailjet` | `:api_key`, `:secret_key` | ✓ (50/request) | `Mailixir.Webhooks.Mailjet` |
| MailPace | `Mailixir.Adapters.MailPace` | `:api_key` | | `Mailixir.Webhooks.MailPace` |
| Mailtrap | `Mailixir.Adapters.Mailtrap` | `:api_key` | | `Mailixir.Webhooks.Mailtrap` |
| Microsoft Graph | `Mailixir.Adapters.MicrosoftGraph` | `:access_token` | | |
| Postal | `Mailixir.Adapters.Postal` | `:api_key`, `:base_url` | | `Mailixir.Webhooks.Postal` |
| Postmark | `Mailixir.Adapters.Postmark` | `:api_key` | ✓ (`/email/batch`) | `Mailixir.Webhooks.Postmark` |
| Resend | `Mailixir.Adapters.Resend` | `:api_key` | | `Mailixir.Webhooks.Resend` |
| Scaleway TEM | `Mailixir.Adapters.Scaleway` | `:secret_key`, `:project_id` | | |
| SendGrid | `Mailixir.Adapters.SendGrid` | `:api_key` | | `Mailixir.Webhooks.SendGrid` |
| SMTP2GO | `Mailixir.Adapters.SMTP2GO` | `:api_key` | | `Mailixir.Webhooks.SMTP2GO` |
| SparkPost | `Mailixir.Adapters.SparkPost` | `:api_key` | | `Mailixir.Webhooks.SparkPost` |
| SMTP | `Mailixir.Adapters.SMTP` | `:relay` (+ optional `gen_smtp` dep) | | |
| sendmail | `Mailixir.Adapters.Sendmail` | — | | |
| Failover chain | `Mailixir.Adapters.Fallback` | `:adapters` | | |
| Dev mailbox | `Mailixir.Adapters.Local` | — | | |
| Log only | `Mailixir.Adapters.Logger` | — | | |
| ExUnit | `Mailixir.Adapters.Test` | — | | |

Every adapter's moduledoc lists how `tags`, `metadata`, `template`, inline
attachments and provider options map onto that API, and which fields the
provider cannot express.

## Installation

Mailixir is not on Hex yet; depend on a release tag:

```elixir
def deps do
  [
    {:mailixir, github: "jothiflow/mailixir", tag: "v0.3.1"},
    {:gen_smtp, "~> 1.2"},  # only for Mailixir.Adapters.SMTP
    {:plug, "~> 1.14"}      # only for the dev mailbox UI / webhook raw-body plug
  ]
end
```

## Phoenix setup

```elixir
# lib/my_app/mailer.ex
defmodule MyApp.Mailer do
  use Mailixir.Mailer, otp_app: :my_app
end

# config/runtime.exs
config :my_app, MyApp.Mailer,
  adapter: Mailixir.Adapters.Postmark,
  api_key: {:system, "POSTMARK_SERVER_TOKEN"},
  message_stream: "outbound"

# config/dev.exs
config :my_app, MyApp.Mailer, adapter: Mailixir.Adapters.Local

# config/test.exs
config :my_app, MyApp.Mailer, adapter: Mailixir.Adapters.Test
```

`{:system, "VAR"}` / `{:system, "VAR", default}` are read at delivery time.
Per-call overrides work too: `MyApp.Mailer.deliver(email, adapter: Mailixir.Adapters.SES)`.

### Dev mailbox

```elixir
# router.ex
if Application.compile_env(:my_app, :dev_routes) do
  scope "/dev" do
    pipe_through :browser
    forward "/mailbox", Mailixir.Plug.Mailbox
  end
end
```

Emails sent through `Mailixir.Adapters.Local` show up at `/dev/mailbox`:
headers, tags, metadata, attachments, text, and the HTML body rendered in a
sandboxed iframe.

### Recipients from your structs

```elixir
defmodule MyApp.Accounts.User do
  @derive {Mailixir.Recipient, email: :email, name: :name}
  schema "users" do ...
end

Mailixir.Email.new(to: user)
```

### Coming from `phx.gen.auth` / Swoosh

The generated `UserNotifier` becomes:

```elixir
import Mailixir.Email

defp deliver(recipient, subject, body) do
  email =
    new()
    |> to(recipient)
    |> from({"MyApp", "contact@example.com"})
    |> subject(subject)
    |> text_body(body)

  with {:ok, _response} <- MyApp.Mailer.deliver(email), do: {:ok, email}
end
```

## Testing

```elixir
import Mailixir.TestAssertions

test "sends a welcome email" do
  Accounts.register(%{email: "jane@example.com"})

  email = assert_email_sent(to: "jane@example.com", subject: ~r/welcome/i)
  assert email.html_body =~ "Jane"
end

test "no email on failure" do
  Accounts.register(%{})
  assert_no_email_sent()
end
```

`refute_email_sent(subject: "…")` and `delivered_emails/0` are there too. The
test adapter follows `$callers`, so emails sent from a `Task` or an inline
Oban job still reach the test process.

## Templates and provider options

```elixir
new()
|> from("no-reply@acme.com")
|> to("jane@example.com")
|> template("welcome", %{name: "Jane"})       # string names (Resend, Mailgun, Mandrill, SES, SendGrid, …)
|> template(1234, %{name: "Jane"})            # numeric ids (Brevo, Mailjet, Postmark)
|> put_provider_option(:track_opens, true)    # anything one provider supports that the struct does not
```

With a template, subject and bodies are optional.

## Batches

```elixir
{:ok, responses} = MyApp.Mailer.deliver_many(emails)
```

Every email is validated first. Postmark and Mailjet send the batch in a
single request; other adapters send one by one. Partial failure returns a
`:batch_failure` error whose `details` list each email's result in order.

## Failover

```elixir
config :my_app, MyApp.Mailer,
  adapter: Mailixir.Adapters.Fallback,
  adapters: [
    [adapter: Mailixir.Adapters.SES, region: "eu-west-1", access_key_id: {:system, "AWS_ACCESS_KEY_ID"}, secret_access_key: {:system, "AWS_SECRET_ACCESS_KEY"}],
    [adapter: Mailixir.Adapters.Postmark, api_key: {:system, "POSTMARK_SERVER_TOKEN"}]
  ]
```

Fails over only when `Mailixir.Error.not_accepted?/1` is true: a
connection-phase failure (refused, DNS, unreachable host, TLS handshake),
429, or 503. A timeout or any other 5xx is returned instead, because the
first provider may already have accepted the message and the next one
cannot deduplicate it. Other 4xx responses are returned immediately,
because the next provider would reject the same email. Pass
`failover_on: fn error -> … end` to change the policy. Each failover emits
`[:mailixir, :fallback, :failover]`.

## Webhooks

Provider callbacks become `%Mailixir.Event{}` structs whose `message_id`
matches the `Mailixir.Response.id` you got when sending:

```elixir
# endpoint.ex — keep the raw body for signature checks
plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  body_reader: {Mailixir.Plug.RawBody, :read_body, []},
  json_decoder: JSON

# controller
def mailgun(conn, _params) do
  case Mailixir.Webhook.parse(Mailixir.Webhooks.Mailgun, conn.assigns.raw_body, conn.req_headers,
         signing_key: System.fetch_env!("MAILGUN_WEBHOOK_KEY")) do
    {:ok, events} ->
      Enum.each(events, &MyApp.Deliverability.record/1)
      send_resp(conn, 200, "")

    {:error, %Mailixir.Error{reason: :invalid_signature}} -> send_resp(conn, 401, "")
    {:error, _} -> send_resp(conn, 400, "")
  end
end
```

Event types: `:accepted`, `:delivered`, `:deferred`, `:bounced` (with
`bounce_type: :hard | :soft` and `reason`), `:complained`, `:opened`,
`:clicked` (with `url`), `:unsubscribed`, `:rejected`, `:other`. Signatures
are verified for Mailgun, SendGrid, Resend, Mandrill, MailPace, Postal,
Facteur and SES (the SNS signature plus an allowed `topic_arn`, since any
AWS account can sign a message to your URL), and basic-auth / bearer /
fixed-header checks for Postmark, Brevo, SparkPost and SMTP2GO, whenever the
key is configured.

## Telemetry

- `[:mailixir, :deliver, :start | :stop | :exception]` — metadata `email`, `adapter`, `provider`, `mailer`, `result`
- `[:mailixir, :deliver_many, …]` — same with `emails` and `count`
- `[:mailixir, :fallback, :failover]` — `adapter`, `provider`, `error`, `email`

Config never appears in metadata. Add request or tenant ids with
`Mailixir.deliver(email, config, telemetry_metadata: %{tenant: id})`.

## Errors

| `reason` | when |
|---|---|
| `:invalid_config` | missing adapter key, unresolved `{:system, …}`, missing optional dep |
| `:invalid_email` | no sender / recipient / subject+body (unless templated) |
| `:api_error` | provider answered non-2xx or reported a rejection (`status`, `details`) |
| `:transport` | connection failure (`details` holds the exception) |
| `:unsupported` | the adapter cannot express the request (e.g. mixed Postmark batch) |
| `:batch_failure` | some emails in `deliver_many` failed (`details` per email) |
| `:invalid_signature` / `:invalid_payload` | webhook verification / decoding failed |

## Checking a provider for real

`mix mailixir.smoke` sends a minimal and a full-featured email (attachment,
inline image, tags, metadata) through every provider whose credentials are in
the environment and prints the result per send:

```sh
MAILIXIR_SMOKE_FROM=you@yourdomain.com MAILIXIR_SMOKE_TO=inbox@example.com \
RESEND_API_KEY=re_… POSTMARK_SERVER_TOKEN=… mix mailixir.smoke
```

`mix help mailixir.smoke` lists the variables for each provider.

## HTTP options

Every HTTP adapter accepts `req_options: [...]`, merged last into the `Req`
request — timeouts, retries, proxies, or `plug: {Req.Test, Stub}` for tests.

## Raw MIME

`Mailixir.MIME.encode/2` builds an RFC 5322 message (quoted-printable text,
base64 attachments, RFC 2047 headers, RFC 2231 filenames, `cid:` inline
parts) with no dependencies; the SMTP, sendmail and Gmail adapters use it.

## Writing an adapter or webhook parser

```elixir
defmodule MyApp.Adapters.Custom do
  use Mailixir.Adapter, provider: :custom, required_config: [:api_key]

  @impl true
  def deliver(%Mailixir.Email{} = email, config) do
    # return {:ok, %Mailixir.Response{}} | {:error, %Mailixir.Error{}}
  end
end

defmodule MyApp.Webhooks.Custom do
  use Mailixir.Webhook, provider: :custom

  @impl true
  def parse(decoded_body, _config), do: {:ok, [%Mailixir.Event{type: :delivered, provider: :custom}]}
end
```

## Related

- [Facteur](https://github.com/jothiflow/facteur) — self-hosted delivery
  platform, reached through `Mailixir.Adapters.Facteur`. Its
  [`docs/stack.md`](https://github.com/jothiflow/facteur/blob/main/docs/stack.md)
  says which concerns belong to mailixir, Facteur and the Héraut notification
  engine, and how to use them together.

## License

MIT
