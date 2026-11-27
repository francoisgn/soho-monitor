# Changelog

Notable changes, newest first. Entries accumulate under "Unreleased" until the first tag (`vX.Y.Z`,
[semver](https://semver.org)).

## Unreleased

### Added

- App icon (#50): stacked glass gauges (blue, orange, purple) on a night blue → indigo gradient, an Icon Composer
  package (`Resources/AppIcon.icon`) compiled by `actool` in `scripts/bundle-app.sh` into `Assets.car` (default,
  dark, tinted, clear) and `AppIcon.icns`; without `actool` the app is built with the generic icon and a warning.
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
