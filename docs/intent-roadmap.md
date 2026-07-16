# Intent Roadmap — Workflow, Standards & Review

> **Status:** Draft direction · **Horizon:** ~2 weeks · **Owner:** Tim Zander
> **Purpose:** An overarching goal document. It sets *intent and sequence*, not a task
> list. Individual work is tracked in GitHub issues (linked per workstream). When a
> decision or trade-off comes up mid-implementation, resolve it against the North Star
> below — that is what this document is for.

## North Star

> **Do deterministically what a machine can decide; reserve human attention (and Opus
> tokens) for genuine judgment — and make the judgment moments fewer, louder, and
> better-signposted.**

Every workstream here is one facet of that single principle. The current pain —
sitting through permission prompts and rubber-stamping them — is the symptom of a
system that treats every decision as equally worthy of a human. The fix is not "fewer
prompts" in the abstract; it is drawing a sharp line between what a machine can safely
decide and what genuinely needs a person, then defending that line everywhere: in
permissions, in standards, in code review, and in how we verify work is correct.

"Fewer and better signals" is not a separate goal. It is what falls out of drawing
that line correctly.

## Guiding Principles

1. **Deterministic beats probabilistic.** If a rule can be enforced by a linter,
   analyzer, hook, or allowlist, it should not live as prose that an LLM re-derives
   every session (and sometimes gets wrong). Move it to the tool.
2. **Differentiate the signal.** A prompt you always approve carries no information.
   Auto-approve the safe, hard-stop the dangerous, and reserve interruption for the
   genuinely ambiguous. The goal is that a permission prompt *means something* again.
3. **Judgment is scarce — spend it well.** Opus tokens and human review minutes are
   the expensive inputs. Feed them mechanical findings pre-digested so they work only
   on what tools cannot catch.
4. **Distribution discipline.** A standard or skill only counts once it reliably
   reaches every developer's machine via `setup-env`. Do not extract knowledge into a
   skill until that skill is guaranteed installed.
5. **Trust the green checkmark.** A passing test that would not catch the regression is
   a false signal — worse than no test. Verification rigor is a first-class outcome,
   not a footnote.

## Current State (baseline)

| Area | Today | The gap this roadmap closes |
|---|---|---|
| Permissions (`standards/settings.json`) | Allowlist has 2 entries; deny is empty | No triage — every prompt is equal weight, so all get rubber-stamped |
| Standards (`standards/CLAUDE.md`) | ~492 lines / ~7.6k tokens, loaded every session | Large share is reference material or machine-enforceable rules that don't need to sit in context |
| Review (`deep-review`) | Opus prose review, fan-out subagents | Zero deterministic tooling — no linters, analyzers, or complexity gate feeding it |
| Distribution (`setup-env.sh`) | Syncs standards + settings + hooks | Does not install skills/plugins, so extraction-to-skills is not yet safe |
| Verification | Standards require tests | Recurring false-green: tests pass while behavior regresses (#184–193) |

## Workstreams

Each workstream states its **intent** (the outcome we want), **why now**, the
**definition of done at the intent level**, and the **tracking issues**. Detailed
task breakdown lives in the issues.

### 1 · Reduce interruption — permission triage
**Intent.** A developer is interrupted only when a decision genuinely needs them. Safe,
read-only operations flow without prompting; dangerous operations hard-stop and demand
real thought.

**Why now.** This is the stated #1 pain and the fastest, lowest-risk relief. It also
*restores meaning* to the prompts that remain, which every later workstream benefits
from.

**Done when.**
- `standards/settings.json` carries a curated **allow** list for genuinely-safe
  read-only operations (e.g. `gh pr view`, `az … show/list`, `git status/log/diff`,
  `rg`, build/test commands) — evidence-based, ideally mined from real transcripts
  rather than guessed.
- It carries a **deny/ask** list for the genuinely dangerous (force-push, `rm -rf`,
  reads/writes of secret files, `curl | sh`) so those always stop the flow.
- The lists distribute cleanly through `setup-env`'s deep-merge and are documented so
  developers understand *why* an entry is safe.

**Tracking:** #183 (allowlist read-only `gh`/`az`) · the `fewer-permission-prompts`
skill (transcript mining) as the evidence source.

### 2 · Close the review loop — review-churn skills
**Intent.** The path from "review produced feedback" to "feedback resolved and verified"
is a supported, low-churn workflow — not a manual slog that spawns endless comment
rounds.

**Why now.** The specs already exist and are sharp; this is the named "good next step."
It also directly attacks the review-comment rubber-stamp cycle.

**Done when.**
- `respond-to-pr-feedback` (#163) exists: triages review comments into decision
  buckets, applies agreed fixes in a worktree, pushes, and replies/resolves threads —
  resolving only the unambiguous ones.
- `verify-pr-resolution` (#164) exists: independently validates each "resolved" thread
  against the actual commits, then approves only on a clean gate (never auto-completes).
- Churn-at-the-source standards land: delete-don't-qualify wrong comments (#188) and
  peer-class-internals comment checks (#118).
- Both skills follow the repo convention: deterministic logic in a tested script with a
  smoke test; judgment stays agent-side.

**Tracking:** #163, #164, #188, #118. Related deep-review hardening: #172, #173, #178,
#179, #181.

### 3 · Slim the standards — extract to guaranteed skills
**Intent.** `standards/CLAUDE.md` holds only always-relevant, terse rules. Reference
material and situational knowledge load on demand via skills that are guaranteed present.

**Why now.** ~7.6k tokens load every session regardless of task. Trimming cuts cost on
every single session and sharpens what remains. The de-risking dependency the team
identified — you can't safely extract to a skill unless the skill is installed — makes
the *ordering* here non-negotiable.

**Done when.**
- `setup-env` installs a **baseline plugin bundle** from the marketplace, so a
  guaranteed skill set exists on every machine (the enabling step).
- Reference-heavy sections (GitHub GraphQL issue-relationships, SQL/TFVC, ADO-MCP
  specifics, log/timezone handling) are extracted from `standards/CLAUDE.md` into
  on-demand skills; the file retains only the always-on rules (naming, C# style, git
  safety, PR sizing).
- Mechanically-enforceable C# rules move out of prose into `.editorconfig` + analyzers
  (#180), shrinking the file *and* making enforcement deterministic.

**Tracking:** #166 (groom standards + guaranteed skill bundle), #180 (.editorconfig),
#130 (route team-applicable memory into shared standards).

### 4 · Measure what we mean — complexity & "Code That Fits in Your Head"
**Intent.** Design-quality expectations that are measurable are *measured*, not opined.
Cyclomatic complexity, method size, nesting depth, and argument counts become gates,
not review prose.

**Why now.** No issue tracks this today — it is a genuine gap. And these metrics are
deterministic by nature, so they belong in the analyzer gate (workstream 5), where they
cost zero tokens and never drift.

**Done when.**
- A tracking issue exists (to be filed) capturing the concrete, measurable heuristics
  from *Code That Fits in Your Head* (e.g. cyclomatic complexity ceiling, the method
  size box, argument limits).
- Those thresholds are wired into the deterministic review gate and/or analyzer config,
  not added as more CLAUDE.md prose.

**Tracking:** *(issue to be filed)* · plugs into #181 and #180.

### 5 · Deterministic code review — the pre-flight gate
**Intent.** Before Opus reads a single line, the mechanical findings are already
collected. The LLM review spends its budget only on what tools cannot catch.

**Why now.** This is the structural, compounding win that serves the explicit ask —
faster reviews, fewer tokens, more consistency — and it is where workstream 4's metrics
plug in. It is sequenced last because it benefits from the standards and metrics work
landing first, but its foundation (#181) can begin in parallel.

**Done when.**
- A pre-flight scan runs the repo's linters, analyzers, complexity checks, secret
  scanning, and diff-coverage, and feeds structured mechanical findings into
  `deep-review`'s analysis step (#181).
- The built-in `security-review` skill is composed in rather than a hand-maintained
  inline checklist (#179).
- Machine-enforceable conventions (branch naming, close-keyword safety) move to hooks
  where they belong (#103, #186).

**Tracking:** #181, #179, #103, #186, #180.

### Cross-cutting · Trustworthy verification
**Intent.** A green test suite is evidence the work is correct — because our tests are
built to fail when the behavior is wrong.

**Why.** "Confidence that work is going in the right direction" was an explicit ask, and
a whole cluster of issues shows tests passing while behavior regressed. This is the
backbone of "better signals."

**Done when.** The verification-rigor standards and skills land: mutation-verify
bug-fix tests, prove a regression fails on base before trusting it, assert observable
outcomes not mechanisms, and verify claims against the running system.

**Tracking:** #184, #185, #189, #191, #193 (verification rigor) · #187 (verify against
running system).

## Sequencing — the ~2-week arc

Framed as horizons, not hard dates. Workstreams are independent enough to reorder; this
order front-loads relief and back-loads compounding structural work.

- **Horizon 1 (relief).** Workstream 1 — permission triage. Small, low-risk, hits the
  #1 pain, and makes every later prompt meaningful.
- **Horizon 2 (the loop).** Workstream 2 — ship #163, then #164; fold in #188/#118.
  In parallel, begin the workstream 5 foundation (#181 pre-flight scaffold) since it is
  independent of the churn skills.
- **Horizon 3 (structural).** Workstream 5 pre-flight matures → workstream 4 metrics
  plug in → workstream 3 standards slim (gated on the baseline-skill bundle). The
  verification-rigor cross-cut lands opportunistically alongside, wherever review and
  standards work touches it.

## Success Signals

How we will know the roadmap is working — watch these, not activity:

- **Interruptions per session drop**, and the prompts that remain are ones you actually
  stop and think about (not rubber-stamp).
- **Standards token load falls** meaningfully from the ~7.6k baseline, with no loss of
  applicable guidance (it moved to skills/analyzers, it didn't disappear).
- **Review cost per PR drops** (fewer Opus tokens) while catch-rate holds or improves —
  mechanical findings arrive pre-digested.
- **Review rounds per PR trend down** — the loop-closing skills and delete-don't-qualify
  norm reduce churn.
- **False-green incidents approach zero** — regressions get caught by tests, not by
  production.

## Out of Scope (for this horizon)

Named so the roadmap stays bounded. Not "never" — "not these two weeks":

- Autonomous PR-review agents running without a human session (#100).
- Local-LLM review infrastructure (#86) and scheduling research (#127) — research-first,
  not implementation this horizon.
- Domain-specific skills unrelated to the core workflow (e.g. DSP, #154).
- Broad C# style micro-rules (#144–153 cluster) except where they fold naturally into
  the `.editorconfig` work in workstream 3.

## Open Decisions

Resolve these as we enter each workstream:

1. **Allowlist source of truth** — mine transcripts via `fewer-permission-prompts` for
   an evidence-based list, or hand-curate a conservative starter set? (Recommend: mine,
   then curate.)
2. **Baseline skill bundle membership** — which plugins are "must-have on every
   machine"? This gates workstream 3 and needs an explicit list.
3. **Complexity thresholds** — adopt the book's defaults verbatim, or calibrate against
   the existing codebases first to avoid a wall of day-one violations?
4. **Enforcement severity** — do deterministic gates (complexity, `.editorconfig`) fail
   the build, or warn first and ratchet? (Recommend: warn-and-ratchet on existing code,
   fail on new.)
