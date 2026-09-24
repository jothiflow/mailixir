# Mailixir — handoff

State of the library, what to do next, and the decisions the code does not
explain. Authoritative for this repo; the platform-wide view is
`../facteur/docs/handoff.md`, and which project owns which concern is
`../facteur/docs/stack.md`.

Last updated 2026-09-24, at commit `f2c4c00` (tag `v0.2.1`).

## Where it stands

Feature-complete for its perimeter: one `Email`, `deliver/2` and
`deliver_many/2` over 21 adapters, webhook parsing into `Mailixir.Event` with
signature or credential checks wherever the provider offers one,
`Adapters.Fallback`, the dev mailbox and test assertions. **234 tests, 0
failures.** The working tree is clean and in sync with `origin/main`.

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

### 1. Make `Adapters.Fallback` stop risking double sends

`Fallback.failover?/1` fails over on **every** `:transport` error and **every**
5xx. A receive timeout or a 500/502/504 does not prove the provider refused the
message; it may have accepted it. The next provider cannot deduplicate, so the
recipient gets the email twice. Héraut's rule (`../heraut/HANDOFF.md`,
"Decided: email providers and failover") is the correct one, and any
app using `Fallback` directly deserves the same:

- **Fail over** only when the provider certainly did not accept the message:
  a connection-phase failure (refused, DNS, unreachable host, TLS handshake),
  429 or 503.
- **Do not fail over** on a receive timeout or any other 5xx. Return the error
  so the caller retries the *same* provider with the *same* idempotency key.
- 4xx: unchanged, return immediately.

Suggested shape: a public classifier on `Mailixir.Error`, such as
`not_accepted?/1` (name it as you see fit), which `Fallback.failover?/1`
delegates to. Héraut can then call the same function instead of
pattern-matching `Req.TransportError` reasons out of `details` itself.
Today `HTTP.request/3` puts the raw `Req`/Mint exception in `details`, which is
a leak of `Req` internals into every caller.

Before writing it, check which `reason` values Req 0.5 / Finch / Mint actually
produce. The open question is whether a connect timeout and a receive timeout
can be told apart, or both surface as `:timeout`. If they cannot, treat
`:timeout` as ambiguous (no failover). Cover each case in
`test/mailixir/adapters/fallback_test.exs`. This changes default behaviour, so
record it in `CHANGELOG.md` and release it as `v0.3.0`.

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

### 3. Remove the test warning

`test/mailixir/adapters/fallback_test.exs:11`: `email` is unused in
`Flaky.deliver/2`. Rename it to `_email`. CI does not fail on it, but it is the
only warning in the suite.

### 4. Release and move the pins

After steps 1–3, tag the release and update every place that pins
`tag: "v0.2.1"`: `README.md` (Installation), `../facteur/docs/stack.md`,
`../facteur/docs/handoff.md` §3, and `../heraut/HANDOFF.md`. Facteur's contract
and e2e tests pull the default branch, so run them once against the new code:

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
