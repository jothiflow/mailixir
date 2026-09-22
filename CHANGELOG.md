# Changelog

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
