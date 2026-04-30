---
name: start-work
description: Start a new unit of work from a GitHub issue or ADO work item — runs Git Hygiene, creates branches/<id>-<slug> in a worktree by default, self-assigns/transitions state, runs codebase research, and hands off a draft plan
argument-hint: "[<id> | #<number>] [--base <branch>] [--no-worktree]"
allowed-tools: Bash, Read, Grep, Glob, Agent, AskUserQuestion, EnterWorktree, mcp__azure-devops__core_list_project_teams, mcp__azure-devops__wit_my_work_items, mcp__azure-devops__wit_get_work_item, mcp__azure-devops__wit_update_work_item, mcp__azure-devops__wit_add_work_item_comment
user-input: optional
model: opus
---

You are starting a new unit of work — picking up a card and lining up everything a developer needs before writing any code. Your deliverable is a **prepared workspace** (clean branch in a worktree, card marked active, codebase research summarized) plus a **draft plan** for the user to review before implementation begins. You do NOT begin implementation.

This skill is the bookend to `craft-pr`: same dual-source GitHub-or-ADO pattern as `improve-stories`, encoding the **Git Hygiene Before New Work**, **Branch Naming and PR Linking**, and **Mark Work Items Active** procedures from `standards/CLAUDE.md` so every developer lands on the same starting line.

## Step 0: Parse arguments

Recognized inputs:
- **Positional:** `7212` (bare numeric → ADO unless a GitHub remote exists, in which case ask), `#29` (always GitHub), or omitted (auto-detect next priority).
- `--base <branch>` — base the new branch on a non-`main` branch (default: `main`). Use this when starting a child task off a long-lived feature branch.
- `--no-worktree` — create the branch in the current checkout instead of a worktree (default: worktree at `.claude/worktrees/<id>-<slug>/`).

If no positional argument is supplied, proceed to Step 1's auto-detect path.

## Step 1: Detect source and fetch the card

Detection logic (same as `improve-stories` Step 0):

- **GitHub** if the argument starts with `#`, OR is bare numeric AND the repo has a GitHub remote (`gh repo view --json url 2>/dev/null` succeeds), OR the user explicitly says "issue".
- **ADO** if the argument is bare numeric AND there's no GitHub remote, OR the user explicitly references an ADO concept (work item, area path, sprint).
- **Ambiguous** (bare numeric with GitHub remote present): use AskUserQuestion — "Did you mean GitHub issue #<N> or ADO work item <N>?".

### GitHub path

- **Specific issue:** `gh issue view <number> --json number,title,state,labels,body,assignees` to fetch the card.
- **Auto-detect:** `gh issue list --assignee @me --state open --json number,title,labels --limit 20`. If empty, also try `gh issue list --state open --label "ready" --json number,title --limit 20` (or whatever "ready for development" label the team uses; ask if unclear). If multiple results, present the list and ask the user which to start. Never auto-pick.

### ADO path

- **Specific work item:** `mcp__azure-devops__wit_get_work_item` for the ID; capture `System.Id`, `System.Title`, `System.State`, `System.WorkItemType`, `System.AreaPath`, `System.Tags`, `System.AssignedTo`, `System.Description`, `Microsoft.VSTS.Common.AcceptanceCriteria`.
- **Auto-detect:** `mcp__azure-devops__wit_my_work_items` for items assigned to the user. Same multi-result handling as GitHub — present and ask.

**State guard:** If the card is in `Active`, `In Progress`, `Resolved`, `Closed`, or `Done`, surface that to the user and ask for confirmation before proceeding. Picking up an in-progress card may step on someone else's work; resuming your own paused card is fine but should be intentional.

## Step 2: Derive a kebab-case slug from the title

Rules (matching the **Branch Naming and PR Linking** standard):
- Lowercase letters, digits, single hyphens between words.
- Strip punctuation: parentheses, brackets, slashes, colons, commas, periods, quotes.
- Collapse whitespace and underscores to single hyphens.
- Trim leading and trailing hyphens.
- Truncate to ≤ 50 characters at a word boundary; never split a word mid-character.

Examples:
- "Add two-factor auth to login flow" → `add-two-factor-auth-to-login-flow`
- "Bug: payment rounding (PR #123)" → `bug-payment-rounding-pr-123`
- "Umbraco 17 — Day Use Parking Stand alone Features" → `umbraco-17-day-use-parking-stand-alone-features`

If the title produces an empty slug (e.g., a non-Latin title with no obvious transliteration), use AskUserQuestion to ask the user for a slug.

## Step 3: Locate the bundled script

Use Glob with the pattern `**/start-work/**/start-work.sh` rooted at the user's home directory `~/.claude/plugins` (resolve `~` to an absolute path before calling Glob).

If Glob returns multiple candidates, skip any whose version directory (the parent of `scripts/`) contains a `.orphaned_at` marker (check with Read). If zero candidates remain, tell the user the plugin may need reinstalling and stop. If multiple remain, use the first (Glob returns most-recently-modified first).

## Step 4: Run Git Hygiene and create the branch

```bash
bash <resolved-script-path> --slug "<slug>" --id "<id>" [--base "<base>"] [--no-worktree]
```

Capture the last lines of stdout:
- `BRANCH=branches/<id>-<slug>` (always present)
- `WORKTREE_PATH=.claude/worktrees/<id>-<slug>` (present only in worktree mode)

If the script exits non-zero, surface its stderr verbatim and stop. The script's failure modes are: dirty working tree (user must commit, stash, or discard), branch already exists locally (user must rename or delete the existing branch), worktree path already exists (likely a paused-and-resumed card — surface that), unreachable origin (network/auth issue), or `--base` doesn't exist on origin.

Omit `--id` if the card has no numeric identifier (rare — typically a developer-initiated branch with no tracked work item). The script handles this: branch becomes `branches/<slug>` with no numeric prefix.

## Step 5: Enter the worktree (worktree mode only)

If `WORKTREE_PATH=` was emitted in Step 4, switch the session into the worktree using `EnterWorktree` with the `path` parameter set to the captured value. The session's working directory becomes the new worktree, and subsequent steps run there.

Skip this step entirely in `--no-worktree` mode (the script already left the user on the new branch in the original checkout).

## Step 6: Mark the work item active

### GitHub
```bash
gh issue edit <number> --add-assignee @me
```
GitHub has no formal state to transition — assignment is the active signal.

### ADO
Use `mcp__azure-devops__wit_update_work_item` to:
1. Set `System.State` to `Active`. Some teams use `In Progress` or another non-default state name — if the project's process template uses a non-`Active` next state, surface the choices and ask the user before guessing.
2. Set `System.AssignedTo` to the current user (look up via `mcp__azure-devops__core_list_project_teams` with `mine=true` if the email isn't readily available, or use the user's `~/.claude/CLAUDE.md`-stored work email).

If the work item is already `Active` and assigned to the current user, this step is a no-op — log it and continue.

## Step 7: Codebase research

Delegate to an `Explore` subagent (specialized agent for fast codebase exploration) so the full search transcript stays out of the main context. Pass the agent:
- The card's title and description (verbatim — the agent uses these to seed its searches)
- A concise prompt asking it to identify candidate files, components, services, models, or patterns related to the work, and to return a short punch list (under 200 words)

Set thoroughness based on the card's apparent scope:
- `quick` — trivially-scoped (typo fix, single-string change, one-bullet acceptance criteria)
- `medium` — typical default
- `very thorough` — only when the user explicitly requests deeper context, or when the card spans clearly distinct surfaces

The agent's compact summary is what enters main context. Never the full search transcript.

## Step 8: Draft the plan and hand off

Present a single structured handoff message in this exact order:

1. **Card** — `[<source> #<id>] <title>` plus a one-line summary of scope drawn from the description.
2. **Workspace** — branch name, worktree path (or "in-place — `--no-worktree`"), base branch, and notable card metadata (state, assignee, tags, area path).
3. **Codebase research** — the punch list returned by Step 7, verbatim.
4. **Draft plan** — 3-7 numbered steps proposing the implementation approach, grounded in the research. Each step is one short sentence. Explicitly call out non-obvious assumptions or open questions ("assumes the validator runs before the cache write — confirm").
5. **Suggested next action** — typically: "Review the plan, then run Plan mode (or proceed directly) to start implementation."

Stop here. The deliverable is the prepared workspace + the draft plan. Do **not** begin implementation; the user reviews and decides how to proceed.

## Rules

- **Never start work on a dirty tree.** The script's clean-tree refusal is the safety rail; do not bypass it with `--allow-dirty` workarounds.
- **Never auto-pick a card** when multiple are available — always present the list and let the user choose.
- **Never enter implementation** in this skill. The deliverable is the prepared workspace plus the draft plan.
- **Confirm before transitioning state** on a card already `Active`, `Resolved`, `Closed`, or `Done`.
- **Worktree is the default.** Only fall back to in-place branch creation when `--no-worktree` is explicit.
