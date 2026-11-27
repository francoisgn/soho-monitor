# Changelog

Notable changes, newest first. Entries accumulate under "Unreleased" until the first tag (`vX.Y.Z`,
[semver](https://semver.org)).

## Unreleased

### Added

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
