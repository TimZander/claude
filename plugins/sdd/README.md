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
`tzander-skills` marketplace (or updates it), installs `sdd`, `handoff` and `gh`, and writes a short
`~/.claude/CLAUDE.md` that points every session at the repository's sdd workflow. If a repository
isn't set up yet, the session tells you and asks rather than running `/sdd:init` itself. It
installs nothing else: no shared team standards and no other plugins. `handoff` adds `/handoff`
and `/pickup`, for resuming work across a `/clear` or in a new session.

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
| `scripts/sdd/check-specs.sh` | plugin | Validates the specs, then again after archiving every active change (catches deltas that validate but archive into invalid specs), and checks every active change is pinned. `--worktree` checks uncommitted edits; `--no-archive` validates only, for a deploy |
| `scripts/sdd/sdd-archive.sh` | plugin | `active`, `run`, `verify` (is an archive PR mechanical?), `verdict` (read a CI log) |
| `scripts/sdd/sdd-specs.mjs` | plugin | `pin` (base pins), and the checks that read requirements: `check`, `gate`, `requirements`, `spec-diff` |
| `scripts/sdd/sdd-config.mjs` | plugin | Reads the repo's `sdd` settings from `package.json` (below) |
| `scripts/sdd/sdd-github.mjs` | plugin | CI only: posts commit statuses and the main-spec diff comment, when the settings ask |
| `scripts/sdd/session-start.sh` | plugin | SessionStart hook: `npm ci --ignore-scripts` when `node_modules` is stale and OpenSpec's skills generated, then one-line status (active changes to archive, learning mode) |
| `scripts/sdd/setup-agent-skills.mjs` | plugin | `prepare` script: generates OpenSpec's skills from the pinned version, for the tools in the settings |
| `.github/workflows/sdd-checks.yml` | plugin | PR checks under `pull_request_target`: runs base-branch code, reads the PR as data (see below) |
| `.claude/sdd-workflow.md` | plugin | The flow agents follow, imported from `CLAUDE.md` with `@.claude/sdd-workflow.md` |
| `.claude/sdd-version` | plugin | Plugin version installed |
| `openspec/conventions.md` | repo | Starter spec conventions, created once |
| `docs/decisions/` | repo | MADR README and template, created once if absent |

Plugin-owned files are overwritten on every run, so keep project rules in `CLAUDE.md`. The
installer only ever adds to the other files:
- `package.json`: the OpenSpec pin and scripts (`openspec`, `spec:validate`, `spec:check`,
  `spec:pin`, `prepare`);
- `.claude/settings.json`: telemetry off, the plugin enabled, the SessionStart hook (added next
  to any hooks the repo already has);
- `.gitignore`;
- `CLAUDE.md`: the import line.

A value the repo already set differently is kept and reported as a warning.

Options: `--openspec-version <x.y.z>` (default `1.14.1`), `--no-ci`, `--no-install`.

**OpenSpec 1.14.1 fails long requirements.** From 1.14.1, `validate --strict` fails any
requirement whose text (above its first scenario) is over 500 characters; 1.14.0 only noted it.
A repository pinned to 1.14.0 can fail wholesale on the bump. `/sdd:init` keeps the repo's pin
and warns: split the long requirements on the old version first, then bump in its own PR.

## Settings

Optional, in the `sdd` field of `package.json`. An unknown key or a wrong type is an error, so
a typo never turns a check off silently. They are always read from the checkout the scripts run
from: in CI, the base branch, never the PR.

| Setting | Default | What it does |
|---|---|---|
| `pins` | `true` | Every active change holds `base-pins.json` (below) |
| `changeNames` | `"default"` | `"lowercase"`: change names are `[a-z0-9][a-z0-9-]*` and don't start with a date. The default is `[A-Za-z0-9][A-Za-z0-9._-]*` |
| `tools` | `["claude"]` | Tools OpenSpec generates its skills for (`openspec init --tools`), such as `["claude", "opencode"]`. Gitignore the other tools' generated folders yourself |
| `specDiffComment` | `true` | CI keeps one PR comment showing the main specs as they will read once the PR's changes are archived |
| `statuses` | `false` | CI also posts a commit status per check (`sdd/spec-checks`, `sdd/requirements-through-change`, `sdd/main-spec-diff`, `sdd/archive-mechanical`), so branch protection can require each by name |
| `archiveVerdicts` | `[]` | More verdicts `/sdd:archive-pr` must see as `success` before merging, each `{ "workflow": ".github/workflows/<file>.yml", "line": "<verdict name>" }` |
| `autoMerge` | `true` | `false`: `/sdd:archive-pr` stops before merging |

## Base pins

OpenSpec's `MODIFIED` replaces a whole requirement. If changes A and B both modify one
requirement, archiving B after A silently drops A's edit, and the archive still looks
mechanical. Pins catch it:

- `npm run spec:pin -- <change>` writes `openspec/changes/<change>/base-pins.json`: for each
  requirement the change's deltas touch, the SHA-256 of its block in the main spec now
  (`MODIFIED`, `REMOVED`, a rename's `FROM`), or `null` (`ADDED`, a rename's `TO`). Blocks are
  read with the pinned OpenSpec CLI's own parser and normalised (CRLF to LF, trailing whitespace
  and repeated blank lines dropped), so the hashes match what timzander.com's `spec:pin` wrote.
- `check-specs.sh` fails when an active change has no pins or they don't cover its deltas.
- On a change PR, `requirements-through-change` fails when a pin doesn't match the base: another
  change edited the requirement first. Merge its text into the delta and re-pin.
- `sdd-archive.sh verify` checks each change's pins against the main spec right before it is
  archived, in archive order, so an archive PR holding both A and B fails on B.

## The CI checks

`sdd-checks` prints one verdict line per check:

| Line | Fails when |
|---|---|
| `spec-checks` | the specs don't validate now, or once every active change is archived, or an active change isn't pinned |
| `requirements-through-change` | a main spec's requirement is added, edited or removed outside an archive; an active change on the base is edited, or deleted instead of archived; a file in an existing archive folder changes; a main spec has two requirements with one name; a new change's pins are stale |
| `main-spec-diff` | archiving the PR's active changes fails. Otherwise it keeps the PR comment up to date |
| `archive-mechanical` | an archive PR isn't exactly `openspec archive` output on the default branch's tip, a pin is stale when its change is archived, or an archived change has unfinished tasks. `not-an-archive-pr` otherwise |

The job fails when any check does. It works in private repositories: the merge commit is
fetched with the job's token, given to that one `git fetch` as an HTTP header in its own
environment, never stored in `.git/config`.

## How the CI checks stay trustworthy

The archive check decides whether a PR merges without review, so a PR must not be able to run
code in it or fake its verdict:

- **Only default-branch code runs.** The workflow checks out the base. The PR's merge commit is
  fetched as data, and only once its second parent is the PR's current head, so a stale merge
  commit is never judged. The settings come from the base too.
- **The token reaches two steps.** The fetch, and the last step that posts statuses and the
  comment. No step that reads the PR's content gets it.
- **The CLI always comes from the trusted checkout.** It is taken from that checkout's
  `node_modules`, never from the PR's tree, and a revision that tracks `node_modules/` fails
  outright.
- **Text from the PR can't start a log line.** CLI output and repo paths are quoted (`  | `,
  `- `), with `::` and `##[` broken. Change names must match `[A-Za-z0-9][A-Za-z0-9._-]*` as a
  whole (a name with a line break fails), or the stricter `lowercase` rule. In the comment, PR
  text sits in code spans and fences longer than any run of backticks inside.
- **Every exit path prints a verdict.** `verify` ends with `archive-mechanical: <state>`
  whatever stops it. `verdict` counts only whole lines, and accepts `success` only right after
  the `- compared base` line.
- **`/sdd:archive-pr` checks where a verdict came from.** It accepts only a run of
  `.github/workflows/sdd-checks.yml` on `pull_request_target` for the PR's head, adopts only
  archive PRs from the repository's own branches, and re-runs `verify` itself, with the default
  branch's scripts, before merging.

## Upgrading from 0.1.0

Re-run `/sdd:init`. Then:
- **Pin the active changes.** `check-specs` now fails on an active change without
  `base-pins.json`; `/sdd:init` lists them. Check each one's deltas still hold the main spec's
  current text before pinning it. Or turn pins off with `"sdd": { "pins": false }`.
- **Private repositories:** 0.1.0's `sdd-checks` couldn't fetch the merge commit, and failed on
  every PR without running a check. 0.2.0 fixes it.
- **The session hook no longer runs install scripts.** If a project needs its dependencies'
  install scripts, run `npm rebuild` (or `npm ci`) yourself once you trust the lock file.
- **Retiring a repository's own copies.** A repository with its own pin script, requirements
  check, main-spec diff or archive check can drop them once the new checks have run on a PR.
  Pins written by timzander.com's `spec:pin` are already in this format.


## Tests

```
bash plugins/sdd/scripts/test_sdd.sh
```

The test runs the installer and the installed scripts against real git repos and a stub
OpenSpec CLI, offline. CI runs it on Linux and macOS (`test-sdd-scripts.yml`).
