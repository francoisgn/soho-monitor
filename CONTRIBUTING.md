# Contributing

Humans and coding agents follow the same path. Agent rules: [`CLAUDE.md`](CLAUDE.md) (Claude Code) and
[`AGENTS.md`](AGENTS.md) (other agents), on top of the [Belayline](https://github.com/francoisgn/belayline-agentic-harness)
harness vendored in `.harness/`.

1. **An issue first** (bug, feature or task form): the intent, the error cases, the definition of done. A small fix
   can do without one (`Direct-PR: <reason>` in the PR).
2. **Claim it**: a comment "Claimed: branch `<branch>`" with a 3 to 5 bullet plan; label `status: claimed`.
3. **A branch** `<type>/<short-name>` from an up-to-date `main` (types: `feat`, `fix`, `chore`, `docs`, `lot`).
4. **Tests first** where there is logic (`SohoMonitorCore`, Swift Testing): seen failing, then passing.
5. `scripts/local-check.sh` ends with `Result: OK`, then a PR from the template; the PR is merged by the maintainer.

Security problems: never in a public issue, see [SECURITY.md](SECURITY.md).
