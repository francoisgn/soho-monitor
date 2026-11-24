# Security policy

## Reporting a vulnerability

Please **do not open a public issue, PR or discussion** for a security problem.

Report it privately from the repository's **Security** tab: **Report a vulnerability**
(GitHub [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)).
The report is only visible to you and the maintainer.

Include what you found, the commit, how to reproduce it and the impact you expect. Never paste a real token,
hostname or IP address. You should get an answer within a week; the project is maintained in spare time, so there is
no guaranteed delay for the fix. Please disclose nothing before the fix is published.

## Supported versions

Only the `main` branch.

## Scope

soho-monitor reads system metrics, scans folders with Full Disk Access and, when configured, calls the APIs of a
Synology NAS, a UniFi console and Anthropic's usage endpoints with the operator's credentials. Its trust boundary
is the operator's own Mac.

| In scope | Examples |
|---|---|
| Credentials | a token or password written to disk outside the Keychain, logged, shown in the UI or sent anywhere but its own service |
| Full Disk Access | the app reading or sending more than folder sizes (file contents, names outside the configured categories) |
| Network | a request to a host the configuration does not name; TLS checks disabled for a non-LAN host |
| Configuration | a YAML file that makes the app run a command, follow a symlink out of the configured paths or crash in a loop |
| Build and CI | a workflow injection, an over-broad token, an unpinned action or dependency |

Out of scope: metrics that are wrong without a security impact (open a normal issue), and the security of the
monitored services themselves.
