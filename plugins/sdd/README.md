# sdd

Spec-driven development on [OpenSpec](https://github.com/Fission-AI/OpenSpec). It packages the
flow proven in `painting` and `timzander.com`:
- `openspec/specs/` is the source of truth;
- one PR carries a change's spec and its code;
- fixes go through the spec;
- changes are archived in their own mechanical PR.

OpenSpec's own skills (`/opsx:propose`, `/opsx:apply`, …) still come from OpenSpec, generated at
the version each repo pins. This plugin is a layer on top of them, not a fork.

## Install

```
/plugin install sdd@tzander-skills
/sdd:init
```

`/sdd:init` sets up the current repository, or updates one set up earlier. Run it again after
updating the plugin.

## Skills

| Skill | When | What it does |
|---|---|---|
| `/sdd:spec-review <change>` | After proposing, before any code | Fresh-agent, read-only review of the change's meaning: contradictions, dangling references, untestable or ambiguous requirements, coverage, scope, undecided requirements |
| `/sdd:conformance-review <change>` | After `/opsx:apply`, before the PR | Fresh-agent review of the code against the spec: every scenario tested, code does what the spec says and nothing unspecified, plus a mutation spot check on the 3 riskiest scenarios. At most 15 findings, each routed to spec, test or code |
| `/sdd:spec-fix <change>` | On any finding, UAT remark or bug | Triage, then spec delta → check → commit, then failing test, then code |
| `/sdd:archive-pr` | Before new work, when a change is still active | Archive-only PR, merged once CI's `archive-mechanical: success` is against the current tip |

`conformance-review` replaces `/deep-review` for ordinary changes. Keep `/deep-review` for the
heavy tier: changes that gate merging, handle secrets or run untrusted code.

## What `/sdd:init` puts in a repo

The skills live in the plugin. A repo holds only what must be there for CI or for every agent
session:

| Path | Owner | Purpose |
|---|---|---|
| `scripts/sdd/openspec.sh` | plugin | Runs the pinned CLI with telemetry off; never falls back to `npx` |
| `scripts/sdd/check-specs.sh` | plugin | Validates the specs, then again after archiving every active change (catches deltas that validate but archive into invalid specs) |
| `scripts/sdd/sdd-archive.sh` | plugin | `active`, `run`, `verify` (is an archive PR mechanical?), `verdict` (read a CI log) |
| `scripts/sdd/setup-agent-skills.mjs` | plugin | `prepare` script: generates OpenSpec's skills from the pinned version |
| `.github/workflows/sdd-checks.yml` | plugin | PR checks under `pull_request_target`: runs base-branch code, reads the PR as data (see below) |
| `.claude/sdd-workflow.md` | plugin | The flow agents follow, imported from `CLAUDE.md` with `@.claude/sdd-workflow.md` |
| `.claude/sdd-version` | plugin | Plugin version installed |
| `openspec/conventions.md` | repo | Starter spec conventions, created once |
| `docs/decisions/` | repo | MADR README and template, created once if absent |

Plugin-owned files are overwritten on every run, so keep project rules in `CLAUDE.md`. The
installer only ever adds to the other files:
- `package.json`: the OpenSpec pin and scripts;
- `.claude/settings.json`: telemetry off, the plugin enabled;
- `.gitignore`;
- `CLAUDE.md`: the import line.

A value the repo already set differently is kept and reported as a warning.

Options: `--openspec-version <x.y.z>` (default `1.14.1`), `--no-ci`, `--no-install`.

## How the CI checks stay trustworthy

The archive check decides whether a PR merges without review, so a PR must not be able to run
code in it or fake its verdict:

- **Only default-branch code runs.** The workflow checks out the base. The PR's merge commit is
  fetched as data, and only once its second parent is the PR's current head, so a stale merge
  commit is never judged.
- **The CLI always comes from the trusted checkout.** It is taken from that checkout's
  `node_modules`, never from the PR's tree, and a revision that tracks `node_modules/` fails
  outright.
- **Text from the PR can't start a log line.** CLI output and repo paths are quoted (`  | `,
  `- `), with `::` and `##[` broken. Change names must match `[A-Za-z0-9][A-Za-z0-9._-]*`.
- **Every exit path prints a verdict.** `verify` ends with `archive-mechanical: <state>`
  whatever stops it. `verdict` counts only whole lines, and accepts `success` only right after
  the `- compared base` line.

## Tests

```
bash plugins/sdd/scripts/test_sdd.sh
```

The test runs the installer and the installed scripts against real git repos and a stub
OpenSpec CLI, offline. CI runs it on Linux and macOS (`test-sdd-scripts.yml`).
