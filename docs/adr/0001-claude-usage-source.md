# ADR 0001: source of the Claude plan usage

- Status: accepted (operator decision, 2026-11-27, [#36](https://github.com/francoisgn/soho-monitor/issues/36));
  amended 2026-11-27 by [#78](https://github.com/francoisgn/soho-monitor/issues/78) (pace colouring, see Decision)
- Scope: the Claude card ([#35](https://github.com/francoisgn/soho-monitor/issues/35)): 5-hour session, weekly and
  per-model weekly limits of the operator's Claude subscriptions, one Claude Code profile (config directory) each.

## Context

The operator has several Claude Code profiles, each with its own `CLAUDE_CONFIG_DIR` and its own login (a Max and a
Team subscription). The app must show, per profile, the percent used and the reset time of each plan limit, without
putting the accounts at risk: no scraping of claude.ai, no token taken out of Claude Code and replayed elsewhere.

## Decision

The source is the **Claude Agent SDK** (`@anthropic-ai/claude-agent-sdk`, Anthropic's official package), method
`query.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({ skipBehaviors: true })`: the structured data
behind Claude Code's `/usage`, fetched by the **unmodified `claude` binary** with the profile's own login.

- A small Node helper ships in the app bundle (`Contents/Resources/claude-usage/usage.mjs`, source in
  [`Helpers/claude-usage/`](../../Helpers/claude-usage/)). For one profile it opens a session whose prompt generator
  never yields, so **no message is sent to the model** (`session.total_cost_usd = 0` in the spike), asks for the usage,
  prints one JSON object and closes the session. It never reads a token, a credentials file or the Keychain.
- The SDK version is pinned exactly (`package.json` + `package-lock.json`); `scripts/bundle-app.sh` runs
  `npm ci --omit=optional --omit=peer --omit=dev` into the bundle. The SDK's own copy of Claude Code (an optional
  platform package, about 370 MB) is not shipped: the helper passes the **installed** `claude` binary through
  `pathToClaudeCodeExecutable` (5 MB in the bundle instead of 430 MB). Adding this npm dependency was approved by the
  operator (#36).
- The app finds `node` and `claude` in the `PATH` of the user's login shell (`$SHELL -ilc`, read once at launch,
  a marker line separates it from what the shell's startup files print), then in `/opt/homebrew/bin`,
  `/usr/local/bin` and `~/.local/bin`. A missing `node` or `claude` is shown in the card with what to install.
- Rows are classified on `kind` only, never on a label (the SDK typings say so): `session` (5-hour window),
  `weekly_all` (all models), `weekly_scoped` (one model, `scope.model.display_name`, e.g. "Fable"). Unknown kinds and
  fields are ignored. The colour starts from the server's `severity` (`normal`, `warning`, `critical`), which the
  client never lowers. **Amendment (#78, operator request)**: the client raises it with a pace reading: warning
  when the share used is above the elapsed share of the window (start = `resets_at` minus the window length:
  5 hours for `session`, 7 days for `weekly_all` and `weekly_scoped`; inferred, since a row has no length field:
  the SDK typings name "plan rate-limit utilization windows (5-hour, 7-day, per-model)" and the legacy
  `five_hour` / `seven_day` / `seven_day_opus` fields),
  critical at 90 % or more. No reset time or an unknown kind: no pace reading. This departs from the SDK's "a client
  never grades a row itself" in one direction only (stricter, never milder than the server).
- Refresh: every `claude.refresh_minutes` (default 5) while the desktop panel is visible; showing it refreshes at once
  each profile last tried at least that long ago. One profile at a time, background quality of service, 30 s timeout.

### Sample (figures only, from the spike)

`subscription_type` per profile: `max` and `team` with `rate_limits_available: true`; a profile that is not logged in
to a plan answers `subscription_type: null`, `rate_limits_available: false`. Rows (`rate_limits.limits[]`):

```json
[{"kind":"session","group":"session","percent":15,"severity":"normal","resets_at":"2026-11-27T12:00:00+00:00","scope":null,"is_active":false},
 {"kind":"weekly_all","group":"weekly","percent":29,"severity":"normal","resets_at":"2026-11-30T00:00:00+00:00","scope":null,"is_active":true},
 {"kind":"weekly_scoped","group":"weekly","percent":6,"severity":"normal","resets_at":"2026-11-30T00:00:00+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}]
```

The figures come from the claude.ai usage endpoint (server side, per the SDK typings of `SDKUsageReport.rate_limits`),
so they include work done elsewhere (cloud sessions, other machines). A profile is identified by its config
directory only.

## Sources reviewed (2026-11-27)

- SDK typings `sdk.d.ts` of `@anthropic-ai/claude-agent-sdk` 0.3.332: `usage_EXPERIMENTAL_…` ("Structured session
  cost/usage data and plan rate-limit utilization"), `SDKUsageReport.rate_limits.limits` ("Classify a row on this,
  never on a label"; `severity`: "a client never grades a row itself"), `pathToClaudeCodeExecutable`,
  `persistSession`.
- Claude Code legal and compliance, "Authentication and credential use"
  (<https://code.claude.com/docs/en/legal-and-compliance.md>): the restriction is on third-party apps collecting or
  intermediating Claude.ai credentials; it "does not prevent an end user from signing in to the unmodified Claude
  Code binary with their own Claude subscription". Here the official binary does the call with its own login.
- Claude Code status line (<https://code.claude.com/docs/en/statusline.md>): its `rate_limits` field has the 5-hour
  and 7-day windows only, no per-model row, and only while a local session runs.

## Rejected

| Option | Why |
|---|---|
| Status line hook writing a cache file per profile | No per-model weekly row; updated only while a local Claude Code session runs (#36 spike) |
| Reading the OAuth token (Keychain, `.credentials.json`) and calling the usage endpoint | Credential intermediation, excluded by the terms above and by #35 |
| Scraping claude.ai, headless browser login | Excluded by #35; brittle |
| Undocumented HTTP endpoints called by the app | Not ours to call; the SDK method is the documented (if experimental) surface |
| The app speaking Claude Code's stream-json control protocol itself (no Node) | That protocol is the SDK's internal one; the operator chose the helper (#36) |
| Shipping the SDK's bundled Claude Code | 370 MB per app bundle for a binary already installed |

## Consequences

- The method is marked experimental: it may be renamed or removed in any SDK release. The version is pinned, and a
  failure degrades the card to "unavailable" for that profile with the helper's message; the last good figures stay,
  dimmed, with their age. A newer SDK is taken deliberately (bump `package.json`, `npm install`, check the card).
- Runtime requirements: Node.js 18.14 or later and Claude Code installed, each profile logged in once with
  `CLAUDE_CONFIG_DIR=<dir> claude`. Each refresh starts `node` and `claude` for about a second per profile.
- A profile's directory must exist: the app does not run the helper for a missing one (Claude Code would create it).
