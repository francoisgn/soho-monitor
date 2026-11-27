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

![SoHo Monitor: CPU, memory, disk and Claude plan usage cards on the desktop panel](docs/images/social-preview.png)

**TL;DR**: one SwiftUI app, configured by a YAML file you version with your dotfiles. It replaces an Übersicht
widget (shell + JSX) with real glass and live sampling; the only helper is a small Node script for the Claude card
(official Claude Agent SDK). Status: the **disk**, **CPU / memory**, **Claude** and **NAS** (Synology) cards work; UniFi is
planned, see the [issues](https://github.com/francoisgn/soho-monitor/issues).

## Features

| Module | What it shows | Status |
|---|---|---|
| Disk | Usage of the startup volume by configurable groups and categories (YAML), segmented bar, legend, top 3 folders per group, free space thresholds | 🟢 done |
| System | CPU and memory cards (large figure, thin bar, sparkline of the last 120 samples, chip and core pills, memory pressure and swap) on the desktop panel; GPU, network, busiest processes and menu bar indicators to come | 🔵 in progress |
| Synology | NAS card: volume usage and health, storage pool and disk health, CPU · RAM · disk activity, temperature and uptime, Docker containers with a status dot, DSM update badge; DSM Web API with a dedicated account, password in the Keychain, per-host TLS policy (system, pinned SHA-256, opt-out), polled only while the panel is shown | 🟢 done |
| UniFi | WAN, devices, clients, throughput, through the UniFi Network local integration API | ⚪ planned |
| Claude | Usage of your Claude plans, one block per Claude Code profile: weekly limit bar, 5-hour session and per-model weekly lines (ring, percent, short reset time), pace colours | 🟢 done |

Design: Apple system fonts (SF Pro, SF Pro Rounded for figures), native materials and Liquid Glass (macOS 26),
subtle gradients, cards inspired by the system monitor of [OnlySwitch](https://github.com/jacklandrin/OnlySwitch)
(MIT).

App icon: three glass gauges (disk, CPU, Claude) on a night blue → indigo gradient, a layered Icon Composer file
(`Resources/AppIcon.icon`) that macOS renders in default, dark, tinted and clear styles:

<p align="center"><img src="docs/images/app-icon.png" alt="App icon: default, dark, tinted light, tinted dark, clear" width="480"></p>

## Disk module

A desktop card (above the wallpaper, below every window, on all Spaces) and a menu bar extra:

<p align="center"><img src="docs/images/disk-card.png" alt="Disk card" width="420"></p>

- **Card**: the CPU and memory cards' header (icon, "Disk", share of the disk used as the large figure; the volume
  name is read by VoiceOver), "X of Y used", free-space pill (orange / red under the configured thresholds), one
  continuous segmented bar (groups by size, `macOS` and `Other` last), legend chips with their size and ⚠︎ when a
  group was measured partially. The legend shows the three biggest configured groups (`macOS` and `Other` only when
  fewer are configured); "+N more" unfolds every chip until "Less" or until the panel is hidden. Hover a segment
  (free space included) or a chip to highlight it and read its name, size and share of the bar in place of "X of Y
  used"; click a chip for the group's three biggest folders (name, path, size, gauge). Drag any card to move the
  panel, double-click one to put it back in its default place: the top-left corner of the main screen, under the menu
  bar. The panel hangs from its top-left corner (the one remembered), so it grows downward as cards are added or
  expand, and it is kept inside the screen (a panel taller than the screen keeps its top visible).
- **Menu**: summary line ("Macintosh HD: 183.9 GB free of 494.4 GB"), last update or "Scanning…", configuration or
  scan errors, Show / Hide Panel, Tile Opacity, Panel Opacity, Rescan Now, Quit.
- **Tile Opacity** (menu): Glass (default, the plain Liquid Glass look), Light Frost, Frosted, Solid or Opaque, applied
  at once to every card of the desktop panel and remembered across launches. Nothing more transparent than
  plain glass: its blur keeps the text legible over a busy wallpaper. With Reduce Transparency on (System Settings ›
  Accessibility › Display), the cards are opaque whatever the choice.
- **Panel Opacity** (menu): 100% (default), 85%, 70%, 55%, 40% or 30%, fades the whole desktop panel (glass, text
  and figures alike) at once and is remembered across launches. It combines with Tile Opacity, which only changes
  the tiles' backgrounds: Opaque tiles at 55% are a solid panel, half see-through. Never fainter than 30%. With
  Increase Contrast or Reduce Transparency on (System Settings › Accessibility › Display), the panel is shown at 100%
  whatever the choice, and the menu says so. The menu bar menu itself is never faded.
- **Scan**: every configured path is measured with `du -k -d 1` (one pass gives its size and its direct
  sub-folders) at background quality of service, every `scan_interval_minutes` (default 30) and on demand. One scan
  at a time, across processes too (a lock file next to the cache: `--scan` refuses while the app scans, and the
  reverse). A failed scan is retried after one interval, not at once. A full pass of a well-filled home folder takes several minutes. iOS simulator runtimes come from
  `xcrun simctl runtime list -j`; the APFS container size, free space and the macOS volumes from `diskutil`.
  The last result is cached in `~/Library/Caches/soho-monitor/disk-snapshot.json`, so the card shows figures at
  launch.
- **Counting rules**: categories are measured in file order; a path counted by an earlier category is subtracted
  from the paths that contain it (net values, never twice, at least 0); a path inside one already counted adds
  nothing. `macOS` = the container's volumes except Data (System, Preboot, Recovery, VM, Update); `Other` = used −
  macOS − everything counted, at least 0 (`du` counts APFS clones in full, so categories can exceed the real use).
  The top 3 of a group are the direct sub-folders of its paths, each net of what was counted at or below it.
- **Full Disk Access**: without it, protected folders (Mail, Messages, other apps' containers) are read partially:
  their chip shows ⚠︎ and the footer says so. Grant it to `SohoMonitor.app` in System Settings › Privacy & Security ›
  Full Disk Access. Signed with your Apple Development certificate (found in the keychain), the grant survives
  rebuilds; an ad hoc signature (no certificate) changes at every build and needs it again.
- **Local Network**: macOS asks once whether SohoMonitor may reach devices on the local network (NAS, UniFi
  controller); without it a LAN host is unreachable (for an IP address: "blocked by macOS Local Network privacy").
  Allow it in System Settings › Privacy & Security › Local Network
  ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)).
- **Headless scan**: `SohoMonitor.app/Contents/MacOS/SohoMonitor --scan` runs one scan with the current
  configuration, writes the cache and prints the groups (useful to check the figures, or to fill the cache from a
  terminal that already has disk access).

### Configuration

One YAML file, `~/.config/soho-monitor/config.yaml` (or `$XDG_CONFIG_HOME/soho-monitor/config.yaml`, or the path in
`$SOHO_MONITOR_CONFIG`). Start from [`config/example.yaml`](config/example.yaml); a symbolic link to a file in your
dotfiles works. The app checks the file every 2 seconds and reloads it when it changes; an invalid file is reported
in the card and the menu (every problem, with its line) and the last valid configuration stays in use. Unknown keys
are warnings.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `disk.scan_interval_minutes` | integer, 1–1440 | 30 | Minutes between two automatic scans |
| `disk.free_space.warning_below_percent` | number, 0–100 | 20 | Free space below this share of the disk: orange pill |
| `disk.free_space.critical_below_percent` | number, 0–100 | 10 | Below this: red pill (must be lower than the warning) |
| `disk.categories` | list, required | — | Categories, measured in this order |
| `disk.categories[].group` | string, required | — | Colour in the bar and chip in the legend; `macOS` and `Other` are reserved |
| `disk.categories[].label` | string | the group | Line in the group's detail; `group`/`label` must be unique |
| `disk.categories[].paths` | list of strings | — | Folders or files; `~` and globs (`*`, `?`, `[…]`) allowed |
| `disk.categories[].source` | `ios-runtimes` | — | Instead of `paths`: iOS simulator runtimes (size from `simctl`) |

A category has either `paths` or `source`. Put the most specific paths first (DerivedData before
`~/Library/Developer`). Quote a path that starts with a YAML indicator (`*`, `&`, `!`, `[`, `{`).

## System module

Two glass cards above the disk card on the desktop panel:

<p align="center"><img src="docs/images/system-cards.png" alt="CPU and memory cards" width="420"></p>

- **CPU**: total usage of all cores (user + system + nice ticks over all ticks between two samples, from
  `host_processor_info`), chip name (`machdep.cpu.brand_string`), core count and the split per performance level
  (`hw.perflevelN`, e.g. "4P + 6E"); hover the figure for user / system. The first second shows "Sampling…": a rate
  needs two samples.
- **Memory**: used share and "used of total" (used = app + wired + compressed, the Activity Monitor-like split of
  `host_statistics64`; cached files and purgeable memory are not counted as used), breakdown on hover, memory
  pressure pill ("Normal" / "Warning" / "Critical", with a coloured dot; event driven: `DispatchSource`
  memory-pressure source, seeded by `kern.memorystatus_vm_pressure_level`), swap used (`vm.swapusage`). Sizes in
  binary units (16 GB = 16 GiB). The bar turns orange / red with the pressure level, or above 85 % / 95 % used when
  the pressure is unknown.
- **Sampling**: once per second, and only while the panel is on screen: hidden, or fully covered by windows
  (`NSWindow` occlusion state), nothing is sampled. After the Mac wakes, the first CPU sample is dropped rather than averaged over the sleep. A
  metric that cannot be read shows a dash and the reason in a red pill, never a fake 0 %.
## Claude module

A second card in the desktop panel, shown when the configuration lists Claude Code profiles:

<p align="center"><img src="docs/images/claude-card.png" alt="Claude card" width="420"></p>

- **Per profile**, in configuration order: its label and plan, a bar with the **weekly** limit (all models), its
  percent and reset; below, one line per other limit, two side by side: the **5-hour session** and each
  **per-model weekly** limit (e.g. Fable), as a small ring, the percent, the name and the time to the reset. Reset
  times are short: `44m`, `3h05`, `2d12h` (`now` once passed, `–` unknown); VoiceOver reads them in full.
- **Colours** (bar and rings): **green** while the usage keeps pace with the window, **yellow** when it runs ahead
  by more than 5 points (more used than the elapsed share of the window plus 5 points: 20 % an hour on the 5-hour
  window, so 25 % one hour in is still green; the elapsed share of the 7 days on a weekly one), **red** at 90 % or
  more whatever the pace. The server's severity is a floor: a row it rates warning or critical is never shown
  milder. VoiceOver says "above pace" or "critical" in words.
- **States**: "Waiting for first update…"; a problem (not logged in, limits unavailable or none reported, Node.js
  or Claude Code not found, config directory not found, helper error or timeout) is written under the block and the
  last good figures stay; figures older than two refresh intervals are dimmed with their age.
<p align="center"><img src="docs/diagrams/claude-usage.svg" alt="Claude usage data flow: the Claude card asks ClaudeUsageProvider, which runs the bundled usage.mjs helper with node (30 s timeout, environment allowlist, CLAUDE_CONFIG_DIR); the helper's Claude Agent SDK session, whose prompt never sends a message, asks the installed claude binary, logged in with the profile's own login, for the plan usage kept on claude.ai; one JSON line (kind, percent, severity, resets_at) comes back to the card. The app and the helper never send a prompt and never read a token, a credentials file or the Keychain." width="100%"></p>
<sub>Source: <a href="docs/diagrams/claude-usage.excalidraw">claude-usage.excalidraw</a> (excalidraw.com › Open).</sub>

- **Source** ([ADR 0001](docs/adr/0001-claude-usage-source.md)): a Node helper bundled in the app
  (`Contents/Resources/claude-usage/`) uses Anthropic's Claude Agent SDK to ask the **installed, unmodified
  `claude`** for the data behind `/usage`, with the profile's own login (`CLAUDE_CONFIG_DIR`). No prompt is sent
  (nothing is spent) and the app never reads a token, a credentials file or the Keychain. The figures come from
  your plan's usage on the server, so they include work done elsewhere.
- **Refresh**: every `claude.refresh_minutes` (default 5) and only while the panel is shown; showing it refreshes at
  once each profile last tried at least that long ago. One profile at a time, at background priority, 30 s timeout.
- **Requirements**: Node.js 18.14+ and Claude Code, found in your login shell's `PATH` or in `/opt/homebrew/bin`,
  `/usr/local/bin`, `~/.local/bin`; each profile logged in once (`CLAUDE_CONFIG_DIR=<dir> claude`, then `/login`).
  Building the app needs `npm` (`scripts/bundle-app.sh` installs the helper's pinned dependency from its lockfile).

| Key | Type | Default | Meaning |
|---|---|---|---|
| `claude.refresh_minutes` | integer, 1–1440 | 5 | Minutes between two refreshes while the panel is shown |
| `claude.accounts` | list | none (card off) | Claude Code profiles, shown in this order |
| `claude.accounts[].label` | string, required | — | Name in the card; unique |
| `claude.accounts[].config_dir` | string, required | — | The profile's `CLAUDE_CONFIG_DIR` (`~` allowed); unique; a missing directory is a warning and the app does not run Claude Code for it |

## Synology module

The NAS card, shown when the configuration has a `synology:` section. Until a password is saved it offers
**Set Up…** (credential window: type the password, test the connection, save it in the Keychain) and **Test** (the
saved password); then it shows the NAS's data:

<p align="center"><img src="docs/images/nas-card.png" alt="NAS card: 90 % used, DS416play, DSM 7.1.1, 54 °C, up 77 days, 792.6 GB free; volume bar 6.88 TB of 7.67 TB; volume almost full and pool attention dots; CPU 79 %, RAM 31 %, disk 59 %; containers 6/6 running; DSM update badge" width="420"></p>
<sub>Rendered from the anonymised test fixtures (`Tests/SohoMonitorCoreTests/Fixtures/Synology`), not a live NAS.</sub>

- **Storage**: the first volume's used share as the large figure, its free space just under it; one bar per volume,
  coloured by DSM's own health (indigo when normal, orange attention or an unknown status, red degraded or crashed);
  a dot for the volume's health ("almost full" when DSM says so) and one for the worst storage pool or disk, named
  when it is not healthy.
- **System**: model, DSM version, system temperature (the card's only one; orange when DSM raises its temperature
  warning) and uptime under the title; CPU (user + system + other load), RAM (`real_usage`) and disk activity (how busy the disks were, all drives
  together: `disk.total.utilization`) on one line, orange from 70 % (RAM 85 %), red from 90 % (RAM 95 %), as the Mac's cards.
- **Containers**: running / total, then one dot per container, problems first: red unhealthy or exited with an
  error, orange stopped, restarting or paused, grey stopped on purpose (`expected_stopped`), green running. Only
  names, images and states are read: never environment variables, command lines or mounts.
- **DSM update**: a badge with the new version when DSM has one, checked every `update_interval_hours`; nothing is
  ever downloaded or installed.
- **States**: a section that cannot be read (no permission for its API, DSM error) shows a red pill while the others
  render; an API the account may not use is not asked again until the configuration or the password changes. When
  the NAS does not answer, the last data stays dimmed with its age, then "Unreachable"; a refused password brings back
  the setup content with the reason; a changed pinned certificate shows the fingerprint now presented.
- **Polling**: every `interval_seconds` (at least 60) and only while the panel is shown and the network is up, one
  request at a time, one login kept between refreshes; backoff up to 10 minutes after failures.
- **Demo**: `SOHO_MONITOR_NAS_DEMO=<folder of recorded DSM answers>` plays them back instead of the NAS (no Keychain,
  no network), e.g. the test fixtures, for screenshots.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `synology.host` | string, required | — | Host name or IP address of the NAS (HTTPS only) |
| `synology.port` | integer | 5001 | DSM HTTPS port |
| `synology.user` | string, required | — | Dedicated DSM account, without 2-factor authentication |
| `synology.keychain_item` | string | `synology` | Keychain item (service `soho-monitor`) holding its password |
| `synology.interval_seconds` | integer, 60–86400 | 60 | Seconds between two refreshes while the panel is shown |
| `synology.sections` | list | all | `storage`, `system`, `update`, `docker`: parts of the card, each with its own calls |
| `synology.expected_stopped` | list of names | none | Containers stopped on purpose: grey, not flagged |
| `synology.update_interval_hours` | integer, 1–168 | 6 | Hours between two DSM update checks |
| `synology.tls` | mapping | system trust | `pin_sha256: "<fingerprint>"` or `allow_self_signed: true` (see `config/example.yaml`) |

## Architecture

<p align="center"><img src="docs/diagrams/architecture.svg" alt="Architecture: config.yaml (polled every 2 s), the disk-snapshot.json cache, macOS (Mach, sysctl, pressure events), the Node helper and the Synology NAS (DSM Web API over HTTPS, login test) feed the five modules of SohoMonitorCore (Config, Disk, System, Claude usage, Synology: DSM login, per-host TLS policy, password in the Keychain), a Swift library with no UI; the SwiftUI app's models (AppModel, SystemModel, ClaudeUsageModel, SynologyModel) drive the menu bar extra and the desktop panel (CPU, memory, disk, Claude and Synology cards). Planned: Synology data cards and the UniFi module, with secrets in the Keychain and calls only to configured hosts." width="100%"></p>
<sub>Source: <a href="docs/diagrams/architecture.excalidraw">architecture.excalidraw</a> (excalidraw.com › Open). Diagrams are exported to SVG by
<code>scripts/export-diagrams.sh</code> (Excalidraw's own export, font embedded).</sub>

| Path | Role |
|---|---|
| `Package.swift` | Swift package: `SohoMonitorCore` (library), `SohoMonitor` (app), tests |
| `Sources/SohoMonitorCore/` | Configuration, collectors, models: no UI, unit-tested |
| `Sources/SohoMonitor/` | SwiftUI app: menu bar extra, desktop panel, cards |
| `Helpers/claude-usage/` | Node helper of the Claude card (pinned Claude Agent SDK, lockfile), copied into the bundle |
| `Tests/SohoMonitorCoreTests/` | Swift Testing suites |
| `config/` | Example configuration |
| `Resources/AppIcon.icon/` | App icon (Icon Composer package: `icon.json` and SVG layers), compiled by `actool` |
| `docs/diagrams/` | README diagrams: Excalidraw sources and their SVG export (`scripts/export-diagrams.sh`, tooling outside the repository) |
| `scripts/bundle-app.sh` | Release build → `build/SohoMonitor.app` (menu bar app, Apple Development certificate if present, else ad hoc) |
| `.harness/`, `.claude/`, `CLAUDE.md`, `AGENTS.md` | Rules for the coding agents ([Belayline](https://github.com/francoisgn/belayline-agentic-harness)) |

## Quick start

Requirements: macOS 26 or later, Xcode 26 or later (Swift 6.2 toolchain); Node.js 18.14+ with `npm` and Claude
Code for the Claude card.

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

<p align="center">
  If soho-monitor saves you a trip to Activity Monitor or a NAS dashboard, you can buy me a coffee:
</p>

<p align="center">
  <a href="https://buymeacoffee.com/francoisgn"><img alt="Buy Me a Coffee"
    src="https://img.shields.io/badge/Buy%20Me%20a%20Coffee-francoisgn-FFDD00?logo=buymeacoffee&logoColor=black"></a>
</p>
