# Mailixir — handoff

State of the library, what to do next, and the decisions the code does not
explain. Authoritative for this repo; the platform-wide view is
`../facteur/docs/handoff.md`, and which project owns which concern is
`../facteur/docs/stack.md`.

Last updated 2026-10-01. `v0.3.0` is tagged and pushed (`b932e12`), and
Facteur and Héraut both pin it. Docs, README and the other repos' HANDOFFs
name that tag.

## Where it stands

Feature-complete for its perimeter: one `Email`, `deliver/2` and
`deliver_many/2` over 21 adapters, webhook parsing into `Mailixir.Event` with
signature or credential checks wherever the provider offers one,
`Adapters.Fallback`, the dev mailbox and test assertions. **245 tests, 0
failures.** Compile with `--warnings-as-errors`, format and Credo `--strict`
were clean on 2026-10-01 (docs and dialyzer last ran clean on 2026-09-25).

Héraut will call `Mailixir.deliver/2` from its own provider adapters, with
**Facteur first and Resend, SES, Brevo as fallbacks**. Failover between them is
Héraut's `DeliveryWorker`, not `Adapters.Fallback`. Those four adapters are the
ones that matter; the rest can stay without anyone relying on them.

## Gates

CI runs these in four jobs, and all of them must pass before a commit:

```sh
mix compile --warnings-as-errors
mix test
mix format --check-formatted
mix credo --strict
mix docs --warnings-as-errors
mix dialyzer
```

The remote is SSH (`git@github.com:jothiflow/mailixir.git`). Pushing over HTTPS
is rejected because the `gh` token lacks `workflow` scope.

## Next steps, in order

### 1. Done — `Adapters.Fallback` no longer risks a double send

`Mailixir.Error.not_accepted?/1` is the policy, and `Fallback.failover?/1`
delegates to it. Héraut's `DeliveryError.from_mailixir/1` calls it too
(`transport_reason/1` supplies the code it stores, so it no longer matches
on `Req` structs).

Req 0.5, Finch and Mint report a connect timeout and a receive timeout as
the same `Req.TransportError` reason, `:timeout`. They cannot be told apart,
so `:timeout` does not fail over. Neither do `:closed`, `:econnreset`, or
any 5xx other than 503. Failover is limited to a connection-phase failure
(`:econnrefused`, `:nxdomain`, `:ehostunreach`, `:enetunreach`,
`{:tls_alert, _}`, `:protocol_not_negotiated`, `{:bad_alpn_protocol, _}`),
429, and 503. The same reasons are recognised on a gen_smtp
`{:network_failure, host, {:error, reason}}` tuple. Covered in
`test/mailixir/adapters/fallback_test.exs`. Recorded in `CHANGELOG.md` as
`0.3.0`, tagged 2026-10-01.

### 2. Smoke-test Resend, SES and Brevo against live accounts

The suite stubs HTTP. Only the Facteur adapter has run against a real server,
in Facteur's `test/e2e/mailixir_e2e_test.exs`. This is the unchecked box in
Héraut's "Before a fallback is relied on in production" list. It needs real
accounts, a verified sending domain at each provider, and Florent's
credentials:

```sh
MAILIXIR_SMOKE_FROM=noreply@<domain> MAILIXIR_SMOKE_TO=<inbox> \
RESEND_API_KEY=… \
AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… AWS_REGION=… \
BREVO_API_KEY=… \
  mix mailixir.smoke --adapter resend --adapter ses --adapter brevo
```

For each provider, check that:

- both the minimal and the full email arrive (attachment, inline `cid:` image);
- `Authentication-Results` shows `dkim=pass` and `dmarc=pass`;
- a webhook from each provider parses through `Mailixir.Webhook.parse/4` and
  carries back the `metadata` that was sent. Resend and SES return it as tags;
  Brevo returns it through `X-Mailin-custom`. Héraut depends on this to
  correlate events without storing provider ids.

Fix whatever breaks, add a regression test with the real payload shape, then
record the date and outcome here and tick the box in `../heraut/HANDOFF.md`.

**Brevo, 2026-09-26: sends pass, webhooks not checked.** `jothiflow.com` is
authenticated at Brevo (DKIM CNAMEs `brevo1`/`brevo2._domainkey`, a
`brevo-code` TXT at the apex, the existing DMARC record). Both smoke emails,
from `notifications@jothiflow.com`, landed in a Gmail inbox with
`dkim=pass header.i=@jothiflow.com`, `dmarc=pass` and SPF passing on Brevo's
return path; the metadata came back as `X-Mailin-Custom`. Two findings:

- The inline image arrives as a plain attachment without a `Content-ID`, as
  the adapter's moduledoc says; Brevo has no inline field.
- **Brevo adds its own `List-Unsubscribe` and an open-tracking pixel.** A
  click blocklists the address inside Brevo where Héraut cannot see it.
  **Fixed in `b932e12`:** the adapter now honours a `{url, mailto}`
  `:list_unsubscribe`, which replaces Brevo's header (verified live). `"none"`
  cannot be honoured without Brevo's Enterprise List-Help option, so the
  adapter refuses it before any request, and `not_accepted?/1` treats that
  `:unsupported` as never sent so a chain moves on. Account and security mail
  (`"none"`) therefore skips Brevo. The open-tracking pixel is not addressed.

Still to do for Brevo: the webhook round trip.

**Resend, 2026-09-26: sends pass, webhooks not checked.** `jothiflow.com`
is verified at Resend in eu-west-1 (DKIM TXT `resend._domainkey`, CNAMEs
`send` and `rsend` to `*.forge.rmta.net`, all DNS only). Both smoke emails
landed in a Gmail inbox with `dkim=pass header.i=@jothiflow.com
header.s=resend`, `dmarc=pass` and SPF passing on `rsend.jothiflow.com`.
The inline image arrived correctly (`multipart/related`, `Content-ID`,
`inline`), and Resend adds no `List-Unsubscribe`. Tags only come back on
webhooks, so that part is unchecked. Before the domain verified, Resend
answered `403 … domain is not verified`; `not_accepted?/1` does not fail
over on that, so a misconfigured fallback stops the chain rather than
passing to the next provider.

Still to do for Resend: the webhook round trip. SES is not smoke-tested:
no credentials were available.

### 3. Done — released and pins moved (2026-10-01)

`v0.3.0` is tagged at `b932e12` and pushed. `README.md`,
`../facteur/docs/stack.md`, `../facteur/docs/handoff.md` and
`../heraut/HANDOFF.md` name it. Héraut's `mix.exs` now depends on the tag
instead of `path: "../mailixir"`, and Facteur's test-only dependency is
pinned to `tag: "v0.3.0"` and by commit in `mix.lock`. Against it: Héraut
`mix precommit` 530 tests, 0 failures, dialyzer clean; Facteur `mix precommit`
454 tests, 0 failures, dialyzer clean (no `MAILIXIR_PATH`). Docker was
needed for the databases.

### Later, only if needed

- **Scaleway webhook parser.** Scaleway TEM can emit events through Topics &
  Events. It is the only adapter whose provider has webhooks but no parser;
  Gmail, Microsoft Graph, SMTP and sendmail have none to parse. It is not in
  Héraut's chain, so it can wait.
- **Publish to Hex.** Florent's call. Installing from GitHub by tag works for
  now.

## Out of scope — do not build these here

Every concern has one owner (`../facteur/docs/stack.md`). Mailixir keeps no
state. These belong elsewhere:

- Failover with a record of each attempt, per-tenant chains, category rules:
  Héraut's `DeliveryWorker`.
- Suppression lists, bounce processing, SMTP retries: Facteur (or the hosted
  provider).
- Template rendering: Héraut. Facteur rejects templated sends, and the Facteur
  adapter returns `:unsupported` for them on purpose.
- `List-Unsubscribe` rendering: Facteur. Mailixir only passes the option.

A Facteur API change updates `../facteur/docs/api.md` first, then
`Adapters.Facteur` / `Webhooks.Facteur`, then Facteur's
`mailixir_contract_test.exs`.
