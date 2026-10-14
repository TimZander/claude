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

### In cloud sessions

Use one cloud environment for all sdd work: **Add cloud environment…**, then paste
[`cloud-setup.sh`](cloud-setup.sh) into its setup script. A cloud session doesn't install the
plugins a repository enables in its `.claude/settings.json`, so the script does it. It adds the
`tzander-skills` marketplace (or updates it), installs `sdd` and `gh`, and writes a short
`~/.claude/CLAUDE.md` that points every session at the repository's sdd workflow. If a repository
isn't set up yet, the session tells you and asks rather than running `/sdd:init` itself. It
installs nothing else: no shared team standards and no other plugins.

Every step is non-fatal and it always exits 0, because a failing setup script fails the session;
problems show as `WARNING` lines in `/root/setup-script.log`. The default "Trusted" network level
allows the access it needs. Each repository's npm packages are installed by its own SessionStart
hook (below), not by the setup script, whose result is cached for the whole environment.

## Decisions and learning mode

The workflow asks for an ADR in `docs/decisions/` for every decision that changes behaviour,
process or tooling, and for every answer the owner gives to an open question. Small
implementation choices need none. Nothing enforces this: it's an instruction.

Learning mode records more: smaller choices, the evidence and the options rejected, and lessons
in `docs/lessons.md`. Turn it on for a repository with a line in its own `CLAUDE.md`:

```
ADR detail: learning
```

or ask for it on a single change.

## Skills

| Skill | When | What it does |
|---|---|---|
| `/sdd:spec-review <change>` | After proposing, before any code | Fresh-agent, read-only review of the change's meaning: contradictions, dangling references, untestable or ambiguous requirements, coverage, scope, undecided requirements |
| `/sdd:conformance-review <change>` | After `/opsx:apply`, before the PR | Fresh-agent review of the code against the spec: every scenario tested, code does what the spec says and nothing unspecified, plus a mutation spot check on the 3 riskiest scenarios. At most 15 findings, each routed to spec, test or code |
| `/sdd:spec-fix <change>` | On any finding, UAT remark or bug | Triage, then spec delta → check → commit, then failing test, then code |
| `/sdd:archive-pr` | Before new work, when a change is still active | Archive-only PR, merged once CI's `archive-mechanical: success` is against the current tip |

`conformance-review` is the code review for every change in this flow. It checks the code
against a spec that was already reviewed for intent, so it doesn't need a general code review
alongside it. A change that decides what merges, handles secrets or runs untrusted code also gets
the built-in `/security-review` and an attack test before it merges.

## What `/sdd:init` puts in a repo

The skills live in the plugin. A repo holds only what must be there for CI or for every agent
session:

| Path | Owner | Purpose |
|---|---|---|
| `scripts/sdd/openspec.sh` | plugin | Runs the pinned CLI with telemetry off; never falls back to `npx` |
| `scripts/sdd/check-specs.sh` | plugin | Validates the specs, then again after archiving every active change (catches deltas that validate but archive into invalid specs) |
| `scripts/sdd/sdd-archive.sh` | plugin | `active`, `run`, `verify` (is an archive PR mechanical?), `verdict` (read a CI log) |
| `scripts/sdd/session-start.sh` | plugin | SessionStart hook: `npm ci` when `node_modules` is stale, then one-line status (active changes to archive, learning mode) |
| `scripts/sdd/setup-agent-skills.mjs` | plugin | `prepare` script: generates OpenSpec's skills from the pinned version |
| `.github/workflows/sdd-checks.yml` | plugin | PR checks under `pull_request_target`: runs base-branch code, reads the PR as data (see below) |
| `.claude/sdd-workflow.md` | plugin | The flow agents follow, imported from `CLAUDE.md` with `@.claude/sdd-workflow.md` |
| `.claude/sdd-version` | plugin | Plugin version installed |
| `openspec/conventions.md` | repo | Starter spec conventions, created once |
| `docs/decisions/` | repo | MADR README and template, created once if absent |

Plugin-owned files are overwritten on every run, so keep project rules in `CLAUDE.md`. The
installer only ever adds to the other files:
- `package.json`: the OpenSpec pin and scripts;
- `.claude/settings.json`: telemetry off, the plugin enabled, the SessionStart hook (added next
  to any hooks the repo already has);
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
