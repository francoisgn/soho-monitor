# Changelog

Notable changes, newest first. Entries accumulate under "Unreleased" until the first tag (`vX.Y.Z`,
[semver](https://semver.org)).

## Unreleased

### Added

- System module, CPU and memory (#3, #4, #5, #6): shared sampling engine (demand tokens, one timer only while a card
  is on screen, 1 s minimum interval, no catch-up burst after sleep, failing metric shown as unavailable); card design
  system (glass card with an opaque fallback under Reduce Transparency, large rounded figure, pills, thin bar,
  sparkline, orange / red levels); CPU card (usage from Mach tick deltas, chip name, core counts and P/E split) and
  memory card (used / total, app / wired / compressed / cached breakdown on hover, pressure from a dispatch source,
  swap) above the disk card on the desktop panel.
- Desktop panel anchored by its top-left corner (default: top-left of the main screen, under the menu bar; saved as
  `panel.topLeft`, the old bottom-left `panel.origin` is dropped): it grows downward and stays inside the screen.
- Claude module (#35, #36–#39): `claude:` configuration section (profiles by `label` and `config_dir`,
  `refresh_minutes`); a bundled Node helper (`Helpers/claude-usage`, pinned Claude Agent SDK) that asks the installed
  `claude` for the plan usage of one profile without sending a prompt (ADR 0001); desktop card per profile with the
  weekly bar, 5-hour session and per-model weekly donuts, reset times, server severity colours, waiting / problem /
  stale states; refreshed only while the panel is shown.
- Disk module (#1): YAML configuration (`~/.config/soho-monitor/config.yaml`, example in `config/example.yaml`) with
  validation, line-located errors, live reload and last valid configuration kept; scanner (`du -k -d 1` at background
  QoS, subtraction of earlier categories, top 3 folders per group, partial flag, iOS runtimes from `simctl`, APFS
  container and macOS volumes from `diskutil`), one scan at a time, snapshot cached in
  `~/Library/Caches/soho-monitor/`; menu bar extra (summary, Show / Hide Panel, Rescan Now, Quit) and desktop-level
  glass card (segmented bar, legend chips, hover detail, top 3 panel, drag to move, double-click to reset);
  `SohoMonitor --scan` headless mode.
- Bootstrap: Swift package (`SohoMonitorCore`, `SohoMonitor` menu bar app, tests), `scripts/bundle-app.sh`,
  Belayline harness subset, pre-commit (swift-format, ShellCheck, actionlint, zizmor, markdownlint, gitleaks), CI on
  GitHub-hosted macOS 26, Dependabot, security policy, MIT licence.
