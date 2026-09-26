# Changelog

## 0.3.0 — 2026-09-25

- `Mailixir.Adapters.Fallback` no longer fails over on every transport error
  and every 5xx. The default policy is `Mailixir.Error.not_accepted?/1`,
  which is true only when the provider certainly did not accept the message:
  a connection-phase failure (refused, DNS, unreachable host, TLS handshake),
  429, or 503. A timeout, `:closed`, `:econnreset`, or any other 5xx is
  returned so the caller retries the same provider with the same idempotency
  key. Req 0.5 reports a connect timeout and a receive timeout as the same
  `:timeout` reason, so a timeout is treated as ambiguous.
  `Mailixir.Error.transport_reason/1` returns that reason without the caller
  matching on a `Req` or Mint struct.
- `Mailixir.Error.not_accepted?/1` is also true for `:unsupported`: an
  adapter returns it before making any request, so failing over is safe.
- `Mailixir.Adapters.Brevo` accepts a `:list_unsubscribe` provider option.
  Brevo adds its own `List-Unsubscribe` to every message and a click
  blocklists the recipient inside Brevo. `%{url: …, mailto: …}` replaces it
  (a URL also gets `List-Unsubscribe-Post: List-Unsubscribe=One-Click`),
  checked against a live send on 2026-09-26. `:none` returns `:unsupported`
  without calling Brevo, because removing the header needs Brevo's
  Enterprise-only List-Help option; a fallback chain moves on to the next
  provider.

## 0.2.1 — 2026-09-22

- `Mailixir.Adapters.Facteur` accepts a `:list_unsubscribe` provider option
  (`:facteur`, `:none`, or `%{url: …, mailto: …}`) for Facteur's
  `list_unsubscribe` send field.
- `Mailixir.Webhooks.SES` verifies SNS signatures (versions 1 and 2) when
  given `topic_arn:` — one ARN or a list — and refuses any other topic. The
  signing certificate must come from an `sns.<region>.amazonaws.com` `.pem`
  URL over HTTPS; it is fetched with `:req_options` and cached per URL. A
  failed fetch is a `:transport` error so the endpoint can answer 5xx and
  let SNS retry. Without `topic_arn:` nothing changes.
- `Mailixir.Webhooks.Brevo` checks `basic_auth: {user, password}` (Brevo
  sends credentials embedded in the webhook URL) or `bearer_token:` (Brevo's
  `auth: %{type: "bearer"}` webhook option).

## 0.2.0 — 2026-09-22

- `Mailixir.Adapters.Facteur` and `Mailixir.Webhooks.Facteur` for the self-hosted
  [Facteur](https://github.com/jothiflow/facteur) delivery platform: tags and
  metadata round-trip onto every event, `:idempotency_key` makes a retried send
  safe, and the `Facteur-Signature` header (HMAC-SHA256 over `"<t>.<body>"`) is
  verified when `secret:` is configured.

## 0.1.0 — 2026-09-21

Initial release.

### Core
- `Mailixir.Email` with pipeable builders, address normalisation (strings, tuples, maps, structs via `Mailixir.Recipient`), regular and inline attachments, tags, metadata, templates, provider options, assigns and private data.
- `Mailixir.deliver/3`, `deliver_many/3` (with adapter-level batch callback) and `Mailixir.Mailer` with `{:system, "VAR"}` config resolution.
- Telemetry spans for `deliver` and `deliver_many`; failover events.
- `Mailixir.Error` with normalised reasons across every adapter.

### Adapters
- HTTP: Amazon SES v2, Brevo, Gmail, Mailchimp Transactional (Mandrill), Mailgun, Mailjet, MailPace, Mailtrap, Microsoft Graph, Postal, Postmark, Resend, Scaleway TEM, SendGrid, SMTP2GO, SparkPost.
- Transport: SMTP (gen_smtp), sendmail — messages built by the dependency-free `Mailixir.MIME` encoder.
- `Mailixir.Adapters.Fallback` failover chain.
- Development: Local (with `Mailixir.Plug.Mailbox` UI), Logger; Test with `Mailixir.TestAssertions`.

### Tooling
- `mix mailixir.smoke` live smoke test across every provider with credentials in the environment.

### Webhooks
- `Mailixir.Webhook` and parsers for Mailgun, SendGrid, Resend, Postmark, Mailjet, Brevo, Mandrill, SES, SparkPost, Mailtrap, MailPace, SMTP2GO and Postal producing `Mailixir.Event`; signature verification where the provider offers it; `Mailixir.Plug.RawBody` body reader.
