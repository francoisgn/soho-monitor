# soho-monitor

![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-Liquid_Glass-0A84FF?logo=swift&logoColor=white)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)
![Swift Package Manager](https://img.shields.io/badge/SwiftPM-package-F05138?logo=swift&logoColor=white)
[![CI](https://github.com/francoisgn/soho-monitor/actions/workflows/ci.yml/badge.svg)](https://github.com/francoisgn/soho-monitor/actions/workflows/ci.yml)
![pre-commit](https://img.shields.io/badge/pre--commit-swift--format_·_gitleaks_·_actionlint-FAB040?logo=precommit&logoColor=white)
![Belayline](https://img.shields.io/badge/harness-Belayline-111111)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-francoisgn-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/francoisgn)

> A native macOS system monitor for a small office / home office: disk usage by **your own categories**, live CPU,
> memory and network, and the services around the Mac (Synology NAS, UniFi network, Claude plan usage), in a
> menu bar extra and a movable Liquid Glass desktop panel.

**TL;DR**: one SwiftUI app, configured by a YAML file you version with your dotfiles. It replaces an Übersicht
widget (shell + JSX) with real glass, live sampling and no helper binaries. Status: **bootstrap**, the disk module
is being migrated; see the [issues](https://github.com/francoisgn/soho-monitor/issues).

## Features

| Module | What it shows | Status |
|---|---|---|
| Disk | Usage of the startup volume by configurable groups and categories (YAML), segmented bar, legend, top 3 folders per group, free space thresholds | 🔵 migrating |
| System | CPU, GPU, memory, network cards with a large figure, a thin bar, a history sparkline, busiest processes; optional menu bar indicators | ⚪ planned |
| Synology | NAS volumes, health, load, containers, through the DSM API with a dedicated read-only account | ⚪ planned |
| UniFi | WAN, devices, clients, throughput, through the UniFi Network local integration API | ⚪ planned |
| Claude | Usage of the operator's Claude plans (session and weekly limits, reset times) | ⚪ planned |

Design: Apple system fonts (SF Pro, SF Pro Rounded for figures), native materials and Liquid Glass (macOS 26),
subtle gradients, cards inspired by the system monitor of [OnlySwitch](https://github.com/jacklandrin/OnlySwitch)
(MIT).

## Architecture

```text
 ~/.config/soho-monitor/config.yaml  (versioned in your dotfiles)
            │ watched, reloaded live
            ▼
 ┌──────────────────────── SohoMonitor.app (menu bar, LSUIElement) ────────────────────────┐
 │  SohoMonitorCore (Swift package library, unit-tested)                                   │
 │    Config (Yams) ─▶ Collectors: disk (du, background, low priority) · system (Mach,     │
 │    sysctl, getifaddrs) · synology (DSM API) · unifi (integration API) · claude usage     │
 │                                  │ snapshots (Codable, cached to disk)                  │
 │  SohoMonitor (SwiftUI)           ▼                                                      │
 │    MenuBarExtra ── desktop panel (NSPanel at desktop level, movable, glass cards)        │
 └──────────────────────────────────────────────────────────────────────────────────────────┘
   Secrets: macOS Keychain only. Network: only the hosts named in the configuration.
```

| Path | Role |
|---|---|
| `Package.swift` | Swift package: `SohoMonitorCore` (library), `SohoMonitor` (app), tests |
| `Sources/SohoMonitorCore/` | Configuration, collectors, models: no UI, unit-tested |
| `Sources/SohoMonitor/` | SwiftUI app: menu bar extra, desktop panel, cards |
| `Tests/SohoMonitorCoreTests/` | Swift Testing suites |
| `config/` | Example configuration |
| `scripts/bundle-app.sh` | Release build → `build/SohoMonitor.app` (menu bar app, ad hoc signature) |
| `.harness/`, `.claude/`, `CLAUDE.md`, `AGENTS.md` | Rules for the coding agents ([Belayline](https://github.com/francoisgn/belayline-agentic-harness)) |

## Quick start

Requirements: macOS 26 or later, Xcode 26 or later (Swift 6.2 toolchain).

```sh
git clone git@github.com:francoisgn/soho-monitor.git && cd soho-monitor
swift build && swift test          # library and tests
scripts/bundle-app.sh --install    # build/SohoMonitor.app, copied to ~/Applications
open ~/Applications/SohoMonitor.app
```

Open `Package.swift` in Xcode to work on the UI. Disk categories need **Full Disk Access** for `SohoMonitor.app`
(System Settings › Privacy & Security › Full Disk Access).

## Development

```sh
pre-commit install            # once per clone (hooks pinned; swift-format comes with the toolchain)
pre-commit run --all-files    # swift-format, ShellCheck, actionlint, zizmor, markdownlint, JSON/YAML, gitleaks
scripts/local-check.sh        # the same as CI, with a summary
```

CI: linters on Linux; `swift format lint`, `swift build`, `swift test` and the app bundle on GitHub-hosted macOS 26;
full-history gitleaks. Coding agents follow [`CLAUDE.md`](CLAUDE.md) / [`AGENTS.md`](AGENTS.md); see also
[CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md) and [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE). The vendored harness files in `.harness/` carry Belayline's own MIT licence
([`.harness/LICENSE`](.harness/LICENSE)).

## Support

If soho-monitor saves you a trip to Activity Monitor or a NAS dashboard, you can buy me a coffee:

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-francoisgn-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/francoisgn)
