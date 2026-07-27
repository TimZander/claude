---
name: review-pr
description: "Use whenever the user wants to review, respond to, comment on, or vote on an Azure DevOps pull request — e.g. \"review PR 4846\", \"review this ADO PR and post my feedback\", \"look at PR 4846 and vote\", \"leave review comments on the PR\". End-to-end ADO PR flow: prints a short PR summary with code highlights, gates before starting the review, delegates the critical review to the deep-review skill, then drafts an overview comment, lets you pick which findings to post as inline PR comments, and casts a vote — publishing to the PR only after you confirm. Also invokable explicitly as /review-pr pr <N> (or an ADO PR URL). Do NOT use for GitHub PRs (use /deep-review then /review) or for reviewing the current local branch / working diff with nothing to publish (use /deep-review or /code-review)."
disable-model-invocation: false # allows agents to invoke via Skill tool, matching deep-review
model: opus
# allowed-tools intentionally omitted: this command needs the deferred azure-devops MCP
# tools (loaded on demand via ToolSearch) plus the Skill tool, which a static whitelist
# would break. It is read-only until the Step 5 gate; all writes are Step 6 only.
---

# /review-pr

> **Run `/clear` first.** A PR review should start from a clean context — prior conversation history only adds noise and cost. A skill can't clear its own context (it runs *inside* the context it would reset — the "self-clearing paradox"), so this is a habit for you before invoking: type `/clear`, then `/review-pr pr <N>`. If the current context is already unrelated and short, skip it.

Review an Azure DevOps pull request and respond to it, in one pass:

1. **Confirm the target** — resolve the PR, print a short summary with code highlights, then **gate**: ask before starting deep-review (it's heavy and checks out the source branch).
2. **Review** — delegate the full critical review to the `deep-review` skill.
3. **Draft** — turn deep-review's output into (a) an optional overview comment, (b) a numbered list of findings you choose from, and (c) a recommended vote.
4. **Confirm** — show you the exact plan and **wait**. You pick which findings are worth posting.
5. **Publish** — only after you say go, post the overview + your selected findings as inline comments and cast the vote (which auto-adds you as a reviewer) in Azure DevOps.

This skill has two gates — one before the review starts, one before anything is written — and never touches the PR before you approve the plan.

## Usage

```
/review-pr pr 4846                    # review + draft response for PR 4846 in the current repo
/review-pr pr 4846 focus on threading # pass a focus area through to deep-review
/review-pr <ADO PR URL>               # full URL, e.g. https://dev.azure.com/bgvone/BGV%20Development/_git/GrandCentral/pullrequest/4846
/review-pr pr 4846 base:develop       # non-default base branch (forwarded to deep-review)
```

**A PR reference is required.** This skill publishes *your* review to a specific PR, so it must know which one. If the arguments contain no `pr <N>` and no ADO PR URL, stop and ask for one — do not review `HEAD`. (`#<N>` is an ADO *work item*, never a PR — reject it as a PR selector.)

## Arguments

The text after `/review-pr` is: **$ARGUMENTS**

If it literally reads `$ARGUMENTS` (unsubstituted), you were invoked by an Agent, not the slash command — look for the arguments in your initial prompt instead.

Split the arguments into two parts:
- **The PR selector** — the `pr <N>` token or ADO PR URL. Keep it; you need the numeric PR ID and the repo/project for the ADO calls.
- **Everything else** — focus areas, `base:<name>`, etc. This is forwarded to deep-review verbatim (see Step 2).

## Step 1: Establish the ADO target

Confirm this is an Azure DevOps repo and pin down `repositoryId`/`project`/`pullRequestId` before doing anything expensive.

1. Read the origin remote: `git remote get-url origin`. If it is not a `dev.azure.com` / `visualstudio.com` remote, stop — this skill is ADO-only. (For GitHub, tell the user to run `/deep-review` then GitHub's `/review`.)
2. Determine **project** and **repo name**:
   - From an ADO PR URL: `.../<org>/<project>/_git/<repo>/pullrequest/<id>` — URL-decode `%20` etc. (`BGV%20Development` → `BGV Development`).
   - From `pr <N>` with no URL: parse the project and repo from the origin remote path. For this org the project is `BGV Development` (see the repo `CLAUDE.md` / global standards).
3. **Resolve the repository GUID** with `repo_get_repo_by_name_or_id` (project + repo name). Per the team standard, always pass the GUID as `repositoryId` to the write tools — a bare name produces misleading errors. Keep `project` around too.
4. Fetch the PR with `repo_get_pull_request_by_id` (GUID + `pullRequestId`). Record its **title**, **source/target branch**, **state**, and **author**. If the state is not `active`, note it — reviewing a completed/abandoned PR is allowed but must be surfaced in your final summary, and you should ask before voting on it.

The ADO MCP tools are deferred — load their schemas first with `ToolSearch("select:mcp__azure-devops__repo_get_repo_by_name_or_id,mcp__azure-devops__repo_get_pull_request_by_id,mcp__azure-devops__repo_create_pull_request_thread,mcp__azure-devops__repo_vote_pull_request,mcp__azure-devops__core_get_identity_ids")` before calling them.

## Step 1b: Summarize the PR (with code highlights)

Before the gate, print a short, **read-only** summary so the user can judge whether the full review is worth it. This must **not** change the working directory — fetch the refs and diff them; do not check anything out (that is deep-review's job in Step 2).

1. Fetch both refs without switching branches: `git fetch origin <sourceBranchShort> <targetBranchShort>` — short names strip `refs/heads/` (e.g. `branches/7984-...` and `main`).
2. Diffstat: `git diff --stat origin/<target>...origin/<source>` (three-dot — changes on the source since it diverged).
3. Code highlights: from `git diff origin/<target>...origin/<source>`, pull 2–4 of the most notable hunks — the ones carrying the actual behavior/contract change, not renames or test churn. Prefer short excerpts (a few lines each) tagged with `file:line`.

Then print, in a few lines:
- **What it does** — 2–3 sentences from the title, description, and diffstat.
- **Changed files** — the diffstat (files, +/-), collapsed to a one-line "N files, +X/-Y" if long.
- **Highlights** — the 2–4 excerpts/bullets with `file:line`, each noting why it matters.

Keep it tight — a pre-read teaser, not the review. If a fetch fails (network, bad ref), say so and fall back to summarizing from the PR title/description alone.

## Step 1c: Confirm before reviewing — GATE

deep-review is a heavy operation: it fans out parallel subagents and **checks out the PR's source branch**, changing the working directory in this repo/worktree (the Step 1b summary did **not** — it only fetched). Do not start it silently.

After the summary above, ask:

> Run deep-review on PR #<id> now? (yes / cancel)

- **yes** — proceed to Step 2.
- **cancel** — stop; nothing was checked out and nothing was written.

If the PR state is not `active`, flag it — the user may not want to spend a full review on a completed/abandoned PR.

## Step 2: Run deep-review

Invoke the `deep-review` skill via the **Skill tool**:

```
Skill(skill: "deep-review", args: "<the PR selector> <forwarded focus/base tokens>")
```

Pass the PR selector through so deep-review resolves and checks out the correct source branch itself (it owns `resolve-pr.sh`, the dirty-tree guard, and branch restore — do not re-implement any of that here). Forward any focus area / `base:` tokens unchanged.

Follow deep-review to completion and **retain its full structured output** — the five sections (⚖️ Verdict, 📋 Summary, 🔍 Findings, 🧪 Test Gaps, ⚡ Bottom Line) plus any 🎯 Context line. That output is the raw material for both the comment and the vote. Do not paraphrase or trim its findings when carrying them forward.

If deep-review stops early (e.g. dirty working tree, checkout failure), surface its message and stop — there is nothing to publish.

## Step 3: Resolve your identity

Get the current user's ADO identity ID with `core_get_identity_ids`, searching on their email (available from session context). You need this only if you intend to add the user as a reviewer *without* voting — casting a vote in Step 6 adds them automatically. Capture it now so the draft can state plainly whether a separate reviewer-add call is even needed.

## Step 4: Map the verdict to a vote

Translate deep-review's ⚖️ Verdict into a recommended ADO vote. This is a **recommendation** the user confirms or overrides in Step 5 — never a silent choice.

| deep-review verdict | Findings present | Recommended vote |
|---|---|---|
| **APPROVE** | no 🔴/🟡, only 💡 or none | `Approved` |
| **APPROVE** | some 💡 worth noting | `ApprovedWithSuggestions` |
| **NEEDS DISCUSSION** | any | `NoVote` (opens the conversation without blocking) |
| **REQUEST CHANGES** | 🟡 only, no 🔴 | `WaitingForAuthor` |
| **REQUEST CHANGES** | one or more 🔴 | `WaitingForAuthor` (default) — offer `Rejected` as the harder option and let the user choose |

Prefer `WaitingForAuthor` over `Rejected` unless the user asks for the hard reject — it signals "changes needed" without the finality the team reserves for genuinely wrong-direction PRs. State your reasoning in one line so the user can override.

## Step 5: List findings, select, and confirm — DO NOT WRITE YET

Present a scannable **plan** and then stop and wait for explicit approval. Nothing below is posted until the user says go.

**5a. Target** — `PR #<id> "<title>"`, source → target branch, state, author. Flag a non-active state here.

**5b. Overview comment (optional)** — offer to post the whole deep-review report (Verdict, Summary, Findings, Test Gaps, Bottom Line) as one top-level PR comment: the review at a glance. Render it as ADO-flavored markdown, preserving real Unicode emoji (🔴 🟡 💡 ✅ ⬜ — they render in ADO). Default this **on** when there are 🔴/🟡 findings; the user can decline it.

**5c. Findings — pick which to post as inline PR comments.** Enumerate every deep-review finding as a numbered, selectable list, one per line, carrying its severity emoji, `file:line`, and description:

```
[1] 🔴 UmbracoGC/Foo.cs:42 — null deref when bar is empty
[2] 🟡 UmbracoGC/Foo.cs:88 — swallowed exception, no logging
[3] 💡 UmbracoGC/Baz.cs:12 — extract magic number to a named const
```

Then ask which to post as **individual inline comments anchored to their `file:line`**, offering shortcuts:
- a severity bucket — `criticals` (🔴), `criticals+warnings` (🔴🟡), `all`, or `none`
- an explicit list — e.g. `1,3,5`

Only findings the user selects get posted. 💡 suggestions default *out* of the selection unless the user opts in — inline nits add noise. (You may drive this with AskUserQuestion, but a plain prompt is fine.)

**5d. Vote** — the recommended enum from Step 4, one line of rationale, and a note that voting auto-adds the user as a reviewer (so no separate reviewer-add is needed unless they want to add themselves *without* voting).

Then restate the concrete plan in one block — overview: yes/no; the exact list of findings that will be posted inline and on which lines; vote: X — and ask plainly:

**"Publish this plan on PR #<id>? (yes / edit / comment-only / skip-vote / cancel)"** and wait.

- **yes** — do Step 6 in full.
- **edit** — adjust the overview toggle, the selected findings, any comment text, or the vote per their instruction; re-present the plan; wait again.
- **comment-only** — post the overview and/or selected inline comments; skip the vote.
- **skip-vote** — same as comment-only.
- **cancel** — write nothing; end.

Publishing to a PR is an outward-facing action on someone else's work. Approval of one plan does not carry to a different PR or a re-run — always re-confirm.

## Step 6: Publish (only after explicit approval)

Execute exactly the approved plan — no more, no less. All calls use the GUID `repositoryId` + `project` from Step 1.

1. **Overview comment** (if approved) — `repo_create_pull_request_thread` with `content` = the approved markdown, `status: "Active"`. Top-level: do **not** set `filePath`/line fields.

2. **Selected inline comments** — one thread per selected finding, anchored to its line:
   - `filePath` = the finding's path with a leading `/` (e.g. `/UmbracoGC/Foo.cs`).
   - Anchor the whole line: set `rightFileStartLine` and `rightFileEndLine` to the finding's line, `rightFileStartOffset: 1`, and `rightFileEndOffset` = (length of that line's text) + 1. Read the single line from the checked-out file to get its length; if the read fails, fall back to `rightFileEndOffset: 2` (anchors at column 1) rather than skipping the anchor.
   - `content` = the finding as a short comment: severity emoji + description (+ a one-line suggestion if deep-review gave one). `status: "Active"` for 🔴/🟡; `Active` (or `Pending`) for 💡.
   - If a finding has no line (file-only or repo-wide), post it as a top-level comment whose text names the file, rather than forcing a bogus anchor.
   - Post sequentially; if one fails, report it and continue with the rest — don't abort the whole batch.

3. **Cast the vote** (unless comment-only/skip-vote) — `repo_vote_pull_request` with `vote` = the approved enum. Adds the user as a reviewer automatically.

4. **Reviewer-only case** — if the user skipped the vote but still wants to be on the PR, add them with `repo_update_pull_request_reviewers` (`action: "add"`, `reviewerIds: [<identity id from Step 3>]`).

If any write fails, report the exact error and which actions completed — do not silently retry with variations (per the troubleshooting standard).

## Step 7: Report

Summarize what was published: the vote cast, whether the overview comment went up, how many inline finding-comments were posted (and on which files/lines, with any that failed), and whether a reviewer-add was needed. Restate any caveat from earlier (non-active PR state, deep-review 🎯 context). Keep it to a few lines.

## Notes

- **Never** post to the PR before Step 5 approval. The review in Step 2 is read-only reconnaissance; the writes are Step 6 only.
- Secrets seen in the diff are read-only context — never echo them into the PR comment (see global Secret Handling standard).
- This skill does not triage or reply to *existing* reviewer threads — it publishes your own review. Handle back-and-forth replies manually or with a follow-up skill.
- One PR per invocation. To review several, run `/review-pr` once per PR so each gets its own confirmation gate.
