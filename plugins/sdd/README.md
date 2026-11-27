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
updating the plugin. It works for repositories on GitHub and on Azure DevOps (Azure Repos); the
host decides which CI template it installs and how `/sdd:archive-pr` merges (see
[Azure DevOps](#azure-devops)).

`/sdd:opt-out` does the opposite for a repository that won't use sdd: it adds *This repository
doesn't use spec-driven development (sdd).* to its `CLAUDE.md` (creating the file if needed) and
commits it, so an sdd environment works there normally and never asks to set it up. It refuses
a repository that is already set up for sdd, and a `CLAUDE.md` with uncommitted changes; a
symlinked `CLAUDE.md` is followed to its target. The line is matched exactly, as written in
[`scripts/optout-line.txt`](scripts/optout-line.txt) (a quote inside a code fence doesn't count),
and running `/sdd:init` later removes it again.

### In cloud sessions

Use one cloud environment for all sdd work: **Add cloud environment…**, then paste
[`cloud-setup.sh`](cloud-setup.sh) into its setup script. A cloud session doesn't install the
plugins a repository enables in its `.claude/settings.json`, so the script does it. It adds the
`tzander-skills` marketplace (or updates it), installs `sdd`, `handoff`, `ci` and `gh`, and writes a
short `~/.claude/CLAUDE.md` that points every session at the repository's sdd workflow and carries
the session rules every repository shares: relay a long orchestrator past 300k tokens, count CI
minutes beside model spend, and take shared CI from TimZander/ci-recipes. If a repository
isn't set up yet, the session asks once, before its first change, rather than running
`/sdd:init` itself: set it up, not now, or never. "Never" runs `/sdd:opt-out`, which adds one
line to the repository's `CLAUDE.md`, *This repository doesn't use spec-driven development
(sdd).*, and commits it. Every later session reads it, so the environment works for repositories
that won't use sdd too; removing the line undoes it. An
existing environment picks up a new version of this text only when you paste the updated script
into its settings. It
installs nothing else: no shared team standards and no other plugins. `handoff` adds `/handoff`
and `/pickup`, for resuming work across a `/clear` or in a new session; `ci` adds `/ci:init`,
`/ci:update` and `/ci:minutes`.

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
| `/sdd:spec-review <change>` | After proposing, before any code | Fresh-agent, read-only review of the change's meaning: contradictions, dangling references, untestable or ambiguous requirements, coverage, scope, undecided requirements, and three questions the code would otherwise answer by accident (existing requirements that see the new state, cost on the target device, waits that never answer) |
| `/sdd:conformance-review <change>` | After `/opsx:apply`, before the PR | Fresh-agent review of the code against the spec: every scenario tested, code does what the spec says and nothing unspecified, plus a mutation spot check on the 3 riskiest scenarios. At most 15 findings, each routed to spec, test or code |
| `/sdd:spec-fix <change>` | On any finding, UAT remark or bug | Triage, then spec delta → check → commit, then failing test, then code |
| `/sdd:archive-pr` | Before new work, when a change is still active | Archive-only PR, merged once it is shown to be mechanical against the current tip: on GitHub, CI's `archive-mechanical: success` plus its own re-run; on Azure DevOps, its own re-run only (CI there is advisory), then a completion that names the verified commit, within the branch's policies, confirmed afterwards |

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
| `scripts/sdd/sdd-github.mjs` | plugin | GitHub CI only: posts commit statuses and the main-spec diff comment, when the settings ask. Inert on Azure DevOps |
| `scripts/sdd/sdd-azure.mjs` | plugin | Azure DevOps: the remote's organization, project and repository, and `/sdd:archive-pr`'s decisions (can this PR be adopted, are its policies met, the pinned completion body). Inert on GitHub |
| `scripts/sdd/sdd-azure-pr.sh` | plugin | Azure DevOps: `/sdd:archive-pr`'s `find`, `open` and `merge` (verify, then complete pinned and confirm), through `az`. Inert on GitHub |
| `scripts/sdd/session-start.sh` | plugin | SessionStart hook: `npm ci --ignore-scripts` when `node_modules` is stale and OpenSpec's skills generated, then one-line status (active changes to archive, learning mode) |
| `scripts/sdd/setup-agent-skills.mjs` | plugin | `prepare` script: generates OpenSpec's skills from the pinned version, for the tools in the settings |
| `.github/workflows/sdd-checks.yml` | plugin | GitHub: PR checks under `pull_request_target`: runs base-branch code, reads the PR as data (see below) |
| `.azure-pipelines/sdd-checks.yml` | plugin | Azure DevOps, instead of the above: the same checks as a PR build, advisory (see below) |
| `.claude/sdd-workflow.md` | plugin | The flow agents follow, imported from `CLAUDE.md` with `@.claude/sdd-workflow.md` |
| `.claude/sdd-version` | plugin | Plugin version installed |
| `openspec/conventions.md` | repo | Starter spec conventions, created once |
| `docs/decisions/` | repo | MADR README and template, created once if absent |

Every script is installed on both hosts; only the CI template differs. Plugin-owned files are
overwritten on every run, so keep project rules in `CLAUDE.md`. The installer only ever adds to
the other files:
- `package.json`: the OpenSpec pin and scripts (`openspec`, `spec:validate`, `spec:check`,
  `spec:pin`, `prepare`), and `"sdd": { "host": "azure-devops" }` on Azure DevOps;
- `.claude/settings.json`: telemetry off, the plugin enabled, the SessionStart hook (added next
  to any hooks the repo already has);
- `.gitignore`;
- `CLAUDE.md`: the import line.

A value the repo already set differently is kept and reported as a warning.

Options: `--openspec-version <x.y.z>` (default `1.14.1`), `--host github|azure-devops`,
`--no-ci`, `--no-install`. Without `--host`, the host is `package.json`'s `sdd.host`, else read
from the `origin` remote (`dev.azure.com` or `*.visualstudio.com` is Azure DevOps), else GitHub.
`sdd.host` is written for an Azure DevOps repository and for any `--host` given, so a later run
keeps it; a `--host` that contradicts it fails: change the setting first. A repository set up
before, now with an Azure Repos origin, is moved to Azure DevOps with a warning, or refused while
it sets GitHub-only settings. An Azure DevOps Server (on-premises) origin isn't supported: it is
set up for GitHub, with a warning. A leftover CI template for the other host is reported too.

**OpenSpec 1.14.1 fails long requirements.** From 1.14.1, `validate --strict` fails any
requirement whose text (above its first scenario) is over 500 characters; 1.14.0 only noted it.
A repository pinned to 1.14.0 can fail wholesale on the bump. `/sdd:init` keeps the repo's pin
and warns: split the long requirements on the old version first, then bump in its own PR.

## Settings

Optional, in the `sdd` field of `package.json`. An unknown key or a wrong type is an error, so
a typo never turns a check off silently. They are always read from the checkout the scripts run
from. On GitHub, CI runs from the base branch, so a PR can't change them for its own checks. On
Azure DevOps, CI runs the PR's own checkout, so a PR's build reads the PR's settings: one more
reason its verdicts are advisory. `/sdd:archive-pr` reads them from the default branch on both.

| Setting | Default | What it does |
|---|---|---|
| `pins` | `true` | Every active change holds `base-pins.json` (below) |
| `changeNames` | `"default"` | `"lowercase"`: change names are `[a-z0-9][a-z0-9-]*` and don't start with a date. The default is `[A-Za-z0-9][A-Za-z0-9._-]*` |
| `tools` | `["claude"]` | Tools OpenSpec generates its skills for (`openspec init --tools`), such as `["claude", "opencode"]`. Gitignore the other tools' generated folders yourself |
| `specDiffComment` | `true` | GitHub only. CI keeps one PR comment showing the main specs as they will read once the PR's changes are archived. On Azure DevOps the diff always goes to the build's summary tab |
| `statuses` | `false` | GitHub only. CI also posts a commit status per check (`sdd/spec-checks`, `sdd/requirements-through-change`, `sdd/main-spec-diff`, `sdd/archive-mechanical`), so branch protection can require each by name |
| `archiveVerdicts` | `[]` | GitHub only. More verdicts `/sdd:archive-pr` must see as `success` before merging, each `{ "workflow": ".github/workflows/<file>.yml", "line": "<verdict name>" }` |
| `autoMerge` | `true` | `false`: `/sdd:archive-pr` stops before merging |
| `host` | `"github"` | `"azure-devops"`: install the Azure Pipelines template, and complete archive PRs through Azure DevOps. `/sdd:init` writes it for an Azure DevOps repository, and for any `--host` given |
| `archiveBypassReviewers` | `false` | Azure DevOps only. `true`: `/sdd:archive-pr` may complete an archive PR it verified past a "Minimum number of reviewers" policy, when that is the only blocking policy not met and no reviewer voted Reject or Waiting for author. Without this setting it never bypasses, and it never approves or votes |

Setting `specDiffComment`, `statuses` or `archiveVerdicts` on Azure DevOps, or
`archiveBypassReviewers` on GitHub, to anything but its default is an error, not a silent
no-op.

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
| `requirements-through-change` | a main spec's requirement is added, edited or removed outside an archive; an active change on the base is edited (other than ticking its open tasks: `[ ]` to `[x]` in its `tasks.md`, nothing else), or deleted instead of archived; a file in an existing archive folder changes; a main spec has two requirements with one name; a new change's pins are stale |
| `main-spec-diff` | archiving the PR's active changes fails. Otherwise it keeps the PR comment up to date |
| `archive-mechanical` | an archive PR isn't exactly `openspec archive` output on the default branch's tip, or a pin is stale when its change is archived. `not-an-archive-pr` otherwise |

Unfinished tasks never fail a check. A task can be left undone on purpose, and a change is
archived exactly as it merged. They are made visible instead: on a change PR, `main-spec-diff`
prints `- tasks-open: <change>: <n> (<task numbers>)` and lists them in its comment, so a
forgotten tick can still be fixed on the branch; on an archive PR, `archive-mechanical` prints a
`- note:` line per change with any, and `/sdd:archive-pr` copies them into the PR's body. A
forgotten tick found after merge can still be fixed in a PR that only ticks it
(`requirements-through-change` allows that).

The job fails when any check does. On GitHub it works in private repositories: the merge
commit is fetched with the job's token, given to that one `git fetch` as an HTTP header in its
own environment, never stored in `.git/config`.

On Azure DevOps, `.azure-pipelines/sdd-checks.yml` prints the same verdict lines from a PR build
of the PR's merge commit, and puts the main-spec diff on the build's summary tab. It runs only
from a Build Validation policy (Azure Repos ignores YAML PR triggers); its verdicts are advisory,
for the reasons below.

## How the CI checks stay trustworthy

The archive check decides whether a PR merges without review, so a PR must not be able to run
code in it or fake its verdict. On GitHub:

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

### Azure DevOps

Azure Pipelines has no `pull_request_target`. A PR build checks out the PR's merge commit and
runs the YAML and scripts in it, so the PR controls what judges it. The pipeline's verdicts are
advisory: a red build is a real failure, a green one proves nothing alone.

| Guarantee | GitHub | Azure DevOps |
|---|---|---|
| Only default-branch code judges a PR in CI | Yes | **No**: the PR's own YAML and scripts run |
| CI catches a hand edit of `openspec/specs/` (`requirements-through-change`) | Yes, can gate merging | Advisory: a PR can disable the check; review is the gate |
| Main-spec diff | A PR comment | The build's summary tab, from the PR's own scripts |
| The archive check `/sdd:archive-pr` relies on | CI's verdict, from a run it checks, plus its own re-run | Its own re-run of `verify` (`sdd-azure-pr.sh merge`), from a clean checkout of the default branch's tip against the PR head. No CI verdict is read |
| A push after the check can't merge unchecked commits | Merge pinned with `--match-head-commit` | Likely, not proven: completion names the verified commit as `lastMergeSourceCommit`, which should make Azure DevOps refuse a newer head. The target can't be pinned: completion goes ahead only when the tip and the PR's `lastMergeTargetCommit` are still the verified tip, a few seconds before. The source and target commits that landed are confirmed afterwards, and a mismatch is reported as unverified |
| The CLI that verifies is the pinned one | CI runs `npm ci` on the default branch | Its install record, not its files: `sdd-azure-pr.sh merge` refuses unless npm's record of the install in `node_modules` matches the default branch's lock file both ways, so an OpenSpec a PR branch's `npm ci` installed doesn't verify. Code that rewrote `node_modules` in place (an install script, a PR's script run in that checkout) isn't caught |
| A PR from a fork, or from another repository, is never adopted | Yes | Yes (`forkSource`, and the PR's repository and project) |
| A merge without review | Allowed for a verified archive PR | A minimum-reviewer policy stops it, unless `archiveBypassReviewers` is set and that is the only unmet blocking policy. The bypass then skips every policy at the moment of completion: it is judged on a fresh read right before, and anything that changes in the seconds between is bypassed too |
| A reviewer's vote against is respected | n/a | Yes: no completion, bypass or not, goes past a Reject or Waiting-for-author vote, or a required reviewer who hasn't approved |
| The merge strategy is one the repository allows | n/a | Yes: read from the branch's "Require a merge strategy" policies, squash first (one commit, so the branch's unverified intermediate commits stay out of the history, unless the policies forbid squash); the source branch is deleted |
| Text from the PR can't forge a log line | `::` and `##[` broken | Not in CI: the PR runs its own scripts, so it can print any `##vso[` command. sdd's scripts break `##vso[` in text they quote, which guards only against text that isn't hostile |

Unproven here, because no test can call Azure DevOps: that a completion naming a
`lastMergeSourceCommit` other than the source branch's head is refused (Microsoft's REST
reference describes the field, but not that check), and the policy evaluation fields and states
`az repos pr policy list` prints. The confirmation after completing is what catches the first
one failing. Unproven too: that `lastMergeTargetCommit` names the default branch's commit the
PR's merge was last computed against, and that Azure DevOps recomputes it when that branch
moves. If it lags, a run waits for it and then ends `timeout`; it never completes against a
target other than the verified tip without the confirmation reporting it.

**Default-branch code against a PR's content, in a pipeline.** Within one repository, no: the
Build Validation build takes its YAML from the PR's merge commit, and checking out the default
branch as a second repository resource doesn't help, because the PR can edit the step that would
run it. A pipeline whose YAML lives in another repository the PR's author can't write to, which
checks out this repository's default branch and runs its scripts against the PR's merge commit,
could give a trustworthy verdict. It is untested here, and it costs a second repository, a
pipeline definition outside this repository's control, and a way for `/sdd:archive-pr` to tell
that pipeline's runs from any other. The local re-run already gives the archive gate without
it, so sdd doesn't ship one.

## Upgrading to 0.4.5

Update the plugin, then re-run `/sdd:init` in each repository to install 0.4.5's
`.claude/sdd-workflow.md`. It gains one rule: a UAT (an owner check) costs the owner as little
time and attention as possible: one link and at most one button that sets it up, only questions
the owner alone can answer, timings taken by the builder, and the kit checked by the builder
first. A repository that wrote its own version of this rule in `CLAUDE.md` can trim it to its
project specifics.

## Upgrading to 0.4.4

Update the plugin (`/plugin update sdd`; cloud sessions' setup does it for you). Nothing in a
repository needs re-running: 0.4.4 changes only the `/sdd:spec-review` skill. Its new pass I asks
three questions of a change (see the table above), and one left unanswered is a should-fix. A
fix that answers one with new behaviour can still call for another round under `/sdd:spec-fix`'s
rule.

## Upgrading to 0.4.3

Re-run `/sdd:init` to install 0.4.3's `sdd-archive.sh`. Its `verify` is stricter in two ways:
- It compares the archive PR's `openspec/` with the reproduction whatever the ignore rules say
  (`.gitignore`, `.git/info/exclude`, `core.excludesFile`). A rule like `[Pp]ackages/` or
  `[Bb]in/` could drop files from the reproduction, so an archive that left out a change's new
  main spec or archived delta could pass, while the complete one failed. `/sdd:archive-pr` now
  checks, before the archive and again before staging, that nothing else is under `openspec/`
  (`git status --porcelain --ignored -uall -- openspec`), then commits with
  `git add -A -f -- openspec`. It stops until `/sdd:init` has installed 0.4.3's script: the
  0.4.3 skill with an older verify would fail every archive that touches an ignored path. An
  archive PR committed without
  `-f` that is still open fails if it dropped an ignored file: commit the missing files with
  `-f` and verify again.
- A reproduction that fails part way, even without a message, ends
  `archive-mechanical: failure` with a reason, never `success`. One this checkout can't run
  (git can't stage the reproduction, the base-pin gate crashes, say) exits 3, so
  `sdd-azure-pr.sh merge` ends `failed`, not `refused`; its output then ends with a `- reason: `
  line in place of `- compared base`. A problem with the PR found before that still exits 1.
  The reproduction's checkout runs no git hooks.

## Upgrading to 0.4.2 on Azure DevOps

Re-run `/sdd:init` to install 0.4.2's `sdd-azure-pr.sh`, `sdd-azure.mjs` and `sdd-config.mjs`.
What changes in behavior:
- A "Minimum number of reviewers" policy a vote rejected now ends `refused`, not `review`: only
  one still waiting for approvals can be bypassed. Reviewers and votes, a build's expiry and a
  merge-strategy policy's settings are read strictly: one missing from what `az` prints ends
  `failed` rather than reading as no objection, a current build or any strategy. Merge-strategy
  policies are read from the PR's own policy evaluations too.
- verify failing to run in the checkout (OpenSpec not installed, say) ends `failed`, not
  `refused`. A build queued again right before completing ends `timeout`, to run again.
- `"specDiffComment": true` is accepted on Azure DevOps (the default, so it asks for nothing
  Azure DevOps can't do); `false` is still an error there.
- `sdd-azure-pr.sh` first checks for `node` and `az` (and warns without az's `azure-devops`
  extension). It rejects an option its mode doesn't take, or one given twice, and holds
  `--default` and `--source` to the same rule as a PR's source branch. Each `SDD_AZ_*` setting
  is at most 86400 seconds.
- `merge` fetches the PR's head into a ref of its own run (`refs/sdd/archive-pr-<id>-<pid>`).
  Once it has sent the completion, the ref is kept, and named, unless the run ends `completed`:
  completing deletes the source branch.
- `find` also reads the page past the first, which must be empty, in case Azure DevOps returns
  fewer open PRs than asked for.

## Upgrading to 0.4.1 on Azure DevOps

Re-run `/sdd:init` to install 0.4.1's `sdd-azure-pr.sh` and `sdd-azure.mjs`: the 0.4.1 skill
expects them. `sdd-azure-pr.sh merge` now refuses to verify unless `node_modules` was installed
from the default branch's lock file, so the checkout it runs in needs a committed
`package-lock.json` of lockfileVersion 2 or later (npm 7+), and `npm ci --ignore-scripts` (dev
dependencies included) run there with npm 7 or later. A repository on yarn or pnpm, or with an
older lock, can't complete archive PRs until it commits one.

## Upgrading to 0.4.0 on Azure DevOps

A repository on Azure DevOps set up by 0.3.x adopts it by re-running `/sdd:init`: it records
`sdd.host` and installs `sdd-azure.mjs` and `sdd-azure-pr.sh`, which `/sdd:archive-pr` needs.
Without `--no-ci` it also installs `.azure-pipelines/sdd-checks.yml`: create a pipeline from it,
add it to the default branch's Build Validation policy, and set `SDD_DEFAULT_BRANCH` on it if
the default branch isn't `main`. A repository that already runs `check-specs.sh` in its own
pipeline can keep that and pass `--no-ci`. Decide on `archiveBypassReviewers`: with a
minimum-reviewer policy and no bypass, every archive PR waits for one approval.

`sdd.host` is a 0.4.0 setting: sdd scripts from 0.3.x reject it as unknown, so every checkout of
the repository runs 0.4.0's scripts once it is recorded (they come with the commit that records
it).

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
