# CLAUDE.md

Instructions for coding agents (Claude Code reads this file; other agents read `AGENTS.md`). Product details: [README.md](README.md).

<!-- harness:begin harness -->
## Shared harness: Belayline 0.5.0-dev

This block is managed by `scripts/harness-sync.sh`, which lives in the [Belayline](https://github.com/francoisgn/belayline-agentic-harness) harness repository, not in this repository: do not edit it here (propose changes in the harness). To update: skill `/harness-update`, or, from the root of this repository, clone the harness at the wanted tag next to it (`git clone --depth 1 --branch vX.Y.Z https://github.com/francoisgn/belayline-agentic-harness.git ../belayline`) then run `../belayline/scripts/harness-sync.sh --target .` (`.harness/docs/ADOPTION.md` §Updates).

**Precedence**: the project rules win over the harness. The project records each deviation from the harness, with its reason, in the "Harness overrides" section of its `AGENTS.md`; its settings go in `.harness/config.json`; everything outside this block belongs to the project. Order on a conflict: "Harness overrides" section, then the rest of the project rules (`AGENTS.md`, `CLAUDE.md`), then `.harness/config.json`, then `.harness/docs/`. Report an unresolved conflict in an issue of the project.

@.harness/docs/ESSENTIALS.md

Read as the task requires (not loaded by default): method `.harness/docs/METHODOLOGY.md`, conventions `.harness/docs/CONVENTIONS.md`, lessons `.harness/docs/LESSONS.md` (self-review before every PR), reviews `.harness/docs/REVIEW-ROUNDS.md`, orchestration and model choice `.harness/docs/ORCHESTRATION.md`, branches and releases `.harness/docs/BRANCHING-RELEASE.md`, CI budget and security `.harness/docs/CI-BUDGET.md`, project README `.harness/docs/README-STANDARD.md`, Mac handoff `.harness/docs/MAC-HANDOFF.md`.
Skills: `/intent`, `/lot-start`, `/lot-finish`, `/local-check`, `/review-round`, `/feedback-triage`, `/lessons-check`, `/readme-update`, `/status-report`, `/compliance-review`, `/lesson-propose`, `/harness-update`.
<!-- harness:end harness -->

## The project

A native macOS system monitor (SwiftUI, macOS 26+): disk usage by configurable categories, live CPU / memory /
network, and SOHO services (Synology DSM, UniFi Network, Claude plan usage), in a menu bar extra and a movable
desktop panel. Configuration: one YAML file (`~/.config/soho-monitor/config.yaml`). Details: [README.md](README.md).

| Path | Role |
|---|---|
| `Sources/SohoMonitorCore/` | Everything testable: config parsing and validation, collectors, models, formatting. No SwiftUI import |
| `Sources/SohoMonitor/` | SwiftUI app: `MenuBarExtra`, desktop panel (`NSPanel`), cards, design tokens |
| `Tests/SohoMonitorCoreTests/` | Swift Testing (`import Testing`, `@Test`, `#expect`) |
| `config/` | Example configuration, documented key by key |
| `Resources/AppIcon.icon/` | App icon, Icon Composer package (`icon.json` + SVG layers); edit it in Icon Composer |
| `scripts/bundle-app.sh` | Release build and `.app` bundle (Apple Development certificate if present, else ad hoc) |

## Build and tests

```sh
swift build && swift test               # library, app, tests (macOS 26 + Xcode 26 or later)
swift format lint --strict --recursive Package.swift Sources Tests
scripts/bundle-app.sh [--install]       # build/SohoMonitor.app
scripts/local-check.sh                  # pre-commit + build + tests, as CI
```

UI changes: run the bundled app and look at it (screenshot in the PR); a passing build is not a working UI.

## Project conventions

- **Swift 6 language mode, strict concurrency.** Collectors are `Sendable`; UI state is `@MainActor` and
  `@Observable`. No force unwrap or `try!` outside tests.
- **Public APIs only by default.** A private API (GPU usage, SMC temperatures) lives behind a configuration flag,
  off by default, isolated in one file, and fails soft.
- **Low footprint.** Live sampling at most once per second and only while visible; heavy work (disk scan) in a
  background task at low priority, results cached on disk; never block the main actor.
- **Secrets in the Keychain only**: never in the YAML, logs, UI or crash output. Network calls only to hosts named in
  the configuration; TLS verification on, except an explicit per-host opt-out for a LAN device's self-signed
  certificate (pinned fingerprint preferred).
- **Configuration**: YAML, validated with clear error messages shown in the UI; unknown keys are warnings; the app
  keeps the last valid configuration when a reload fails.
- **Design**: SF Pro / SF Pro Rounded (`.system(design: .rounded)` for figures), native materials and
  `glassEffect` (macOS 26), subtle gradients, Apple system colours, light and dark.
- **Language**: English for code, docs, commits and UI strings.

## Branches and CI

- Model B: one integration branch, `main`, protected by `guard-git` (and a GitHub ruleset). Work on
  `<type>/<short-name>`; several agents may work at once, each in its own `git worktree`.
- Commits: `<zone>: <message>` in English (`disk:`, `system:`, `ui:`, `config:`, `synology:`, `unifi:`, `claude:`,
  `build:`, `ci:`, `docs:`, `harness:`).
- CI (`.github/workflows/ci.yml`): pre-commit on Linux, swift-format / build / tests / bundle on GitHub-hosted
  `macos-26`, gitleaks on the full history. Never a self-hosted runner (public repository).

## Project-specific labels

One `area:` per issue (`.github/labels.local.json`): `disk`, `system`, `synology`, `unifi`, `claude`, `ui`, `config`,
`build`. Plus the harness labels (`type:`, `priority:`, `status:`, `difficulty:`).
