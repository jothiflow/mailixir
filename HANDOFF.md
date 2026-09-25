# Mailixir — handoff

State of the library, what to do next, and the decisions the code does not
explain. Authoritative for this repo; the platform-wide view is
`../facteur/docs/handoff.md`, and which project owns which concern is
`../facteur/docs/stack.md`.

Last updated 2026-09-25. `mix.exs` is `0.3.0`, not tagged; `origin/main` is
still `f2c4c00` (`v0.2.1`). The Fallback change below is in the working tree.

## Where it stands

Feature-complete for its perimeter: one `Email`, `deliver/2` and
`deliver_many/2` over 21 adapters, webhook parsing into `Mailixir.Event` with
signature or credential checks wherever the provider offers one,
`Adapters.Fallback`, the dev mailbox and test assertions. **238 tests, 0
failures.** Credo `--strict`, docs and dialyzer were clean on 2026-09-25.

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
`0.3.0`. Not tagged — see step 3.

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

### 3. Release and move the pins

The unused `email` in `Flaky.deliver/2` is already `_email`. After step 2,
tag `v0.3.0` and update every place that pins `tag: "v0.2.1"`:
`README.md` (Installation), `../facteur/docs/stack.md`,
`../facteur/docs/handoff.md` §3, and `../heraut/HANDOFF.md`. Héraut's
`mix.exs` currently uses `path: "../mailixir"` so it can call
`not_accepted?/1` before the tag exists; that becomes the tag in this step.
Facteur's contract and e2e tests pull the default branch, so run them once
against the new code:

```sh
cd ../facteur && MAILIXIR_PATH=../mailixir mix test
```

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
