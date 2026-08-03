---
name: review-pr
description: "End-to-end Azure DevOps pull request review and response, run explicitly as /review-pr pr <N> (or with an ADO PR URL): prints a short PR summary with code highlights, gates before starting the review, delegates the critical review to the deep-review skill, then drafts an overview comment, lets you pick which findings to post as inline PR comments, and casts a vote — publishing to the PR only after you confirm. Not model-invocable: it writes to someone else's pull request, so it is never auto-selected; an agent that wants the analysis should invoke deep-review, which publishes nothing. Do NOT use for GitHub PRs (use /deep-review then /review) or for reviewing the current local branch / working diff with nothing to publish (use /deep-review or /code-review)."
argument-hint: "pr <N> [focus…] [base:<branch>]"
disable-model-invocation: true # writes to someone else's PR — never auto-selected (deep-review sets false because it is read-only)
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
/review-pr <ADO PR URL>               # full URL, e.g. https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/4846
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

**1. Confirm the host first.** Read the origin remote: `git remote get-url origin`. If it is not a `dev.azure.com` / `visualstudio.com` remote, stop — this skill is ADO-only. (For GitHub, tell the user to run `/deep-review` then GitHub's `/review`.) This check comes before the tool load below deliberately: on a GitHub repo, an unavailable ADO MCP server would otherwise produce "connect the azure-devops server" when the real answer is "wrong skill for this host".

**2. Load the ADO MCP tool schemas.** They are deferred, so they cannot be called until fetched:

```
ToolSearch("select:mcp__azure-devops__repo_repository,mcp__azure-devops__repo_pull_request,mcp__azure-devops__repo_pull_request_thread_write,mcp__azure-devops__repo_pull_request_write,mcp__azure-devops__core_get_identity_ids")
```

These five cover every ADO call this skill makes. They are **action-dispatched** — one tool per resource, with the operation in an `action` parameter — so `repo_pull_request_write` serves both the vote (Step 6.3) and the reviewer-add (Step 6.4), and no sixth tool is needed.

**If ToolSearch returns no matching tools, stop.** An empty result is a *silent* outcome, not an error: it means the `azure-devops` MCP server is not connected in this session. Do not improvise tool names and do not substitute `az` CLI writes. Tell the user the server is unavailable and that they need to connect it before re-running — nothing has been read or written at this point, so stopping here is free.

With the host confirmed and the schemas loaded:

3. Determine **org**, **project**, and **repo name**. Every ADO remote dialect carries all three, so none of them has to be hardcoded or guessed:
   - `https://dev.azure.com/<org>/<project>/_git/<repo>`
   - `git@ssh.dev.azure.com:v3/<org>/<project>/<repo>` (and the `vs-ssh.visualstudio.com:v3/...` variant)
   - `https://<org>.visualstudio.com/<project>/_git/<repo>`
   - An explicit ADO PR URL wins when the user passed one: `.../<org>/<project>/_git/<repo>/pullrequest/<id>`.
   - URL-decode percent escapes in every case — `BGV%20Development` → `BGV Development`. Project names routinely contain spaces.
   - If the remote is ADO but genuinely yields no project segment, ask the user for the project name. Never fall back to a default: a wrong project resolves the wrong repo GUID, and this command writes.
4. **Resolve the repository GUID** — `repo_repository` with `action: "get"`, `repositoryNameOrId: <repo>`, `project: <project>`. Per the team standard, always pass the GUID as `repositoryId` to the write tools; a bare name produces misleading errors. Keep `project` around too.
5. **Fetch the PR** — `repo_pull_request` with `action: "get"`, `repositoryId: <GUID>`, `pullRequestId: <id>`. Record its **title**, **description**, **source/target branch**, **state**, and **author**. If the state is not `active`, note it — reviewing a completed/abandoned PR is allowed but must be surfaced in your final summary, and you should ask before voting on it. Voting on a completed or abandoned PR is rejected by ADO, so expect Step 6.3 to fail there even if the user approves it.
   - Pass `includeChangedFiles: true` as well. ADO's own changed-file list is the authority on what its Files tab diff contains — which is exactly what decides whether an inline comment renders there (Step 6.2a) — and unlike the local git diff in Step 1b it is available even when the source ref cannot be fetched. Where the two disagree (force-push, unusual merge base), prefer the API list.

## Step 1b: Summarize the PR (with code highlights)

Before the gate, print a short, **read-only** summary so the user can judge whether the full review is worth it. This must **not** change the working directory — fetch the refs and diff them; do not check anything out (that is deep-review's job in Step 2).

1. Fetch both refs without switching branches: `git fetch origin <sourceBranchShort> <targetBranchShort>` — short names strip `refs/heads/` (e.g. `branches/7984-...` and `main`).
2. Diffstat: `git diff --stat origin/<target>...origin/<source>` (three-dot — changes on the source since it diverged).
3. **Diff file set** — `git diff --name-only origin/<target>...origin/<source>`, reconciled with the `includeChangedFiles` list from Step 1.5 (prefer the API list on any disagreement). Keep it; Step 6.2a needs it to decide which findings can be anchored inline at all. Capturing it here is deliberate: this is the one point in the flow where both refs are guaranteed fetched and no checkout has happened.
4. Code highlights: from `git diff origin/<target>...origin/<source>`, pull 2–4 of the most notable hunks — the ones carrying the actual behavior/contract change, not renames or test churn. Keep each excerpt short (a few lines), and render it as a **fenced code block** with the language hint for the file (`csharp`, `ts`, `razor`, …).

Note that everything in this step compares against the **PR's own target branch**, even when the user passed a `base:<name>` token. That token is forwarded to deep-review (Step 2) and changes what deep-review reviews, but not this summary and not the diff file set — which is correct, because ADO renders inline threads against the PR's real target. Expect more Step 6.2a demotions than usual when a `base:` override is in play, and say so at the gate rather than letting it look like a bug.

Then print the summary as a **top-down flow** — broadest context first, narrowing to specific code — so the user reads from "what/where" down into "how" and can stop as soon as they've seen enough. Use these sections in this order:

1. **Header** — one line: `PR #<id> "<title>"`, `<source> → <target>`, state, author. The at-a-glance identity of the PR.
2. **What it does** — 2–3 sentences from the title, description, and diffstat. The intent, before any code.
3. **Changed files** — the diffstat (files, +/-), collapsed to a one-line "N files, +X/-Y" if long. Where the change lives.
4. **Highlights** — last, because it's the deepest detail: the 2–4 excerpts, each shown as a fenced code block preceded by a `file:line` label and a one-line note on why it matters. Prefer showing the changed lines with enough surrounding context to read (a diff `+/-` hunk is fine when the change is a small edit; a plain snippet when it's new code). For example:

  `LoginWithUsernameRoutes.cs:37` — impersonation is gated on the four tile sections, not a single role.
  ````
  ```csharp
  routeGroup.MapPost("/impersonate", ImpersonateAsync)
      .RequireAuthorization(SectionAccessPolicy.ForSections(
          Sections.OwnerRelations, Sections.OnProperty, Sections.Arm, Sections.Sales));
  ```
  ````

Keep it tight — a pre-read teaser, not the review.

**If the fetch in step 1 fails, diagnose it here rather than letting it surface two steps later.** The most likely cause is a PR whose source branch lives in a **fork**, so `origin/<source>` does not exist. Note that `resolve-pr.sh`'s explicit fork rejection is on its **GitHub** arm only (it reads `isCrossRepository`); the ADO arm never inspects the fork source, so deep-review will not reject this case up front — it will resolve the PR fine and then fail at its own `git fetch origin <source>` / checkout. Catching it here turns that late, confusing failure into a clear one.

Check with `git ls-remote --exit-code origin <sourceBranchShort>`: if the ref is absent, say so plainly ("PR #<id>'s source branch is not on origin — likely a fork PR; deep-review cannot check it out, and inline comments cannot be anchored") and stop instead of walking the user through a gate that leads nowhere. For any other fetch failure (network, transient), say so and fall back to summarizing from the PR title/description alone — but without `origin/<source>` there is no diff file set and no way to read line content, so inline anchoring is off the table entirely: the review becomes top-level-comment-only (Step 6.2 treats a missing file set as "demote everything").

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

**Its five-section report is not the end of this turn.** deep-review's own self-check states that its output has "EXACTLY five sections… No other sections exist" — that is a constraint on *its report format*, not a stop instruction for the caller. When it finishes you are still inside `/review-pr`, with Steps 3–7 outstanding. Treat the report as intermediate input and continue.

Two consequences of `Skill` being an in-context load rather than an isolated subagent, worth knowing so neither surprises you:

- deep-review's diff reading and subagent output land in **this** context window, not a separate one. That is the cost of the shared context, and the reason for the `/clear` habit at the top of this file.
- deep-review owns the working-directory changes (checkout, dirty-tree guard, ref restore). What is on disk by Step 6 is therefore **unknowable from here**: it restores `ORIG_REF` — whatever the user had checked out, which is usually neither the source nor the base — except when it was already on the source branch (no checkout happened) or when it is running in a worktree (restore skipped). That is why Step 6.2c reads file content from `origin/<source>` by name instead of from disk: the correct revision is the same in all three cases.

If deep-review stops early (e.g. dirty working tree, checkout failure), surface its message and stop — there is nothing to publish.

## Step 3: Resolve your identity — only when it is actually needed

**Skip this step on the common path.** Casting a vote in Step 6.3 adds the user as a reviewer automatically, so an identity ID is needed *only* for the reviewer-only case in Step 6.4: the user declines the vote but still wants to be on the PR. Since that is decided at the Step 5 gate, defer the lookup until you know it applies — an unconditional call here spends a round trip that almost every run throws away.

When you do need it, call `core_get_identity_ids` with `searchFilter` = the user's email address. Two things to handle rather than assume:

- **The session email is a starting guess, not the ADO identity.** ADO matches on the Entra/AAD identity, which often differs from what the session reports (personal vs work domain, alias vs UPN, a display name that resolves where the address does not). If the lookup comes back empty, that mismatch is the first thing to suspect.
- **The result is not guaranteed to be exactly one.** `core_get_identity_ids` can return **zero** matches (wrong address, or no ADO identity in this org) or **several** (a shared display name or alias). On zero, say so and ask the user for the address ADO knows them by. On more than one, print the candidates and ask which one — never silently take the first. A wrong identity ID adds a stranger to someone's PR as a reviewer.

## Step 4: Map the verdict to a vote

Translate deep-review's ⚖️ Verdict into a recommended ADO vote. This is a **recommendation** the user confirms or overrides in Step 5 — never a silent choice.

First **count the findings by severity**: `R` = number of 🔴, `Y` = number of 🟡, `S` = number of 💡. Then take the first row whose verdict and condition both match. The conditions are written on those three counts so the mapping is total and unambiguous — exactly one row applies to any review deep-review can produce:

| # | Verdict | Condition | Recommended vote |
|---|---|---|---|
| 1 | **APPROVE** | `R = 0`, `Y = 0`, `S = 0` | `Approved` |
| 2 | **APPROVE** | `R = 0`, `Y = 0`, `S > 0` | `ApprovedWithSuggestions` |
| 3 | **APPROVE** | `R = 0`, `Y > 0` | `ApprovedWithSuggestions` — state the 🟡 count in the rationale; an approval carrying warnings deserves a sentence saying so |
| 4 | **APPROVE** | `R > 0` | `NoVote` — an APPROVE verdict alongside 🔴 findings is self-contradictory. Do not quietly resolve it either way: show the contradiction and ask the user which they trust |
| 5 | **NEEDS DISCUSSION** | any | `NoVote` (opens the conversation without blocking) |
| 6 | **REQUEST CHANGES** | `R = 0` | `WaitingForAuthor` |
| 7 | **REQUEST CHANGES** | `R > 0` | `WaitingForAuthor` (default) — offer `Rejected` as the harder option and let the user choose |

If the verdict text is not one of those three (deep-review phrased it unexpectedly, or the report is malformed), do not guess a vote: recommend `NoVote`, quote the verdict line verbatim, and let the user decide.

Prefer `WaitingForAuthor` over `Rejected` unless the user asks for the hard reject — it signals "changes needed" without the finality the team reserves for genuinely wrong-direction PRs. State your reasoning in one line so the user can override.

## Step 5: List findings, select, and confirm — DO NOT WRITE YET

Present a scannable **plan** and then stop and wait for explicit approval. Nothing below is posted until the user says go.

**5a. Target** — `PR #<id> "<title>"`, source → target branch, state, author. Flag a non-active state here.

**5b. Overview comment (optional)** — offer to post the whole deep-review report (Verdict, Summary, Findings, Test Gaps, Bottom Line) as one top-level PR comment: the review at a glance. Render it as ADO-flavored markdown, preserving real Unicode emoji (🔴 🟡 💡 ✅ ⬜ — they render in ADO). Default this **on** when there are 🔴/🟡 findings; the user can decline it. Say in the plan whether it will be posted as an unresolved (`Active`) or resolved (`Closed`) thread, per the status rule at the top of Step 6 — that is the difference between a review that blocks PR completion and one that does not, and it holds even when the user declines the vote.

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

Mark any finding that **cannot** be anchored inline right here in the list, e.g. `(top-level — file not in diff)` or `(top-level — line not on the right side)`, applying the Step 6.2a/6.2b tests against the diff file set from Step 1b. The user is choosing what to publish; they should not learn only afterwards that a finding they picked as an inline comment landed as a general one.

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

Execute exactly the approved plan — no more, no less. Every call passes `repositoryId` (the GUID from Step 1), `project`, and `pullRequestId`, on the action-dispatched write tools.

**Thread status — resolve it once, before posting anything.** Let `VOTE` be the vote the user approved, or — on the `comment-only` / `skip-vote` paths, where no vote is cast — the **Step 4 recommendation**. It is never undefined: a comment-only run still has a verdict behind it, and keying status off a vote that was never cast is exactly how an approving review ends up blocking the PR it approved. Then:

- A thread carrying a 🔴 or 🟡 finding is always `"Active"`. Those *should* hold up completion until the author responds.
- Every other thread — the overview and 💡 findings — is `"Closed"` when `VOTE` is `Approved` or `ApprovedWithSuggestions`, and `"Active"` otherwise.

Under ADO's **comment-requirements branch policy** an unresolved thread blocks PR completion, and `Pending` counts as unresolved exactly like `Active` — it is not the softer middle option it looks like. A `Closed` thread renders identically to an `Active` one.

1. **Overview comment** (if approved) — `repo_pull_request_thread_write` with `action: "create"`, `content` = the approved markdown, and `status` per the rule above. Top-level: do **not** set `filePath` or any line/offset field.

2. **Selected inline comments** — one thread per selected finding. Both anchoring tests run *before* any write, because both failure modes are silent: ADO accepts the call and the comment simply lands somewhere the author will never look.

   **2a. Is the file in the diff?** A finding may name a file the PR never touched — deep-review reads full files and greps callers, so findings on unchanged files are normal output, not an edge case. ADO accepts a thread anchored outside the diff but renders it **only in the Overview tab**. Check the finding's path against the **diff file set** from Step 1b. If the path is not in that set, **demote** to a top-level comment (2d). If there is no diff file set at all — Step 1b's fetch fallback — then nothing is anchorable: demote every finding and say so once.

   **2b. Does the cited line exist on the right side, and is it the code the finding is about?** Read the line you need for the offset anyway:

   ```
   git show origin/<sourceBranchShort>:<path>
   ```

   `<path>` here is the repo-relative path **without** a leading slash — the leading `/` belongs only to ADO's `filePath` field, and `git show origin/x:/UmbracoGC/Foo.cs` fails outright. Take line N and check it:
   - If the file has fewer than N lines, or the line's content plainly is not what the finding describes, **demote**. The usual cause is a finding about **deleted** code: its line number refers to the base side, and the tool exposes only `rightFile*` parameters — there is no left-side anchor — so anchoring it would pin the comment to unrelated content. This content check is the only mechanical test available; `file:line` alone cannot tell a removed line from an added one.
   - If the `git show` itself fails (ref not fetched, path absent from the source branch), **demote** rather than anchor on a guess. Do not fall back to a column-1 anchor here: a wrong-but-plausible anchor is worse than an honest top-level comment, and the fallback would hide a systematic problem (e.g. a leading slash on every path) behind results that all look fine.

   Read from `origin/<source>` by name, never from disk — by this point the checked-out ref is whatever deep-review restored (see Step 2), which is usually neither the source nor the base.

   **2c. Anchor** — for a finding that survives 2a and 2b:
   - `filePath` = the finding's path **with** a leading `/` (e.g. `/UmbracoGC/Foo.cs`).
   - Anchor the whole line: `rightFileStartLine` and `rightFileEndLine` = the finding's line, `rightFileStartOffset: 1`, `rightFileEndOffset` = (length of the line read in 2b) + 1. For an empty line use `rightFileEndOffset: 2`, which anchors at column 1 — a zero-width `1 → 1` range is not verified against the API and there would be no second fallback.
   - `content` = the finding as a short comment: severity emoji + description (+ a one-line suggestion if deep-review gave one).
   - `status` per the rule at the top of this step.
   - Post sequentially; if one fails, report it and continue with the rest — don't abort the whole batch.

   **2d. Top-level fallback** — for a finding with no line at all (file-only or repo-wide) or one demoted by 2a/2b: post it as a top-level comment (`action: "create"`, no `filePath`) whose text names the file and line, rather than forcing a bogus anchor. Keep a count of demotions and their reasons; Step 7 reports them so the user knows which findings did not land inline.

3. **Cast the vote** (unless comment-only/skip-vote) — `repo_pull_request_write` with `action: "vote"` and `vote` = the approved enum. Adds the user as a reviewer automatically.

4. **Reviewer-only case** — if the user skipped the vote but still wants to be on the PR: `repo_pull_request_write` with `action: "update_reviewers"`, `reviewerAction: "add"`, and `reviewerIds: [<identity id>]`. The operation and the add/remove choice are **two separate fields** — `action` selects `update_reviewers`, `reviewerAction` selects `add`. This is the only path that needs the Step 3 identity lookup, so do it here if it was deferred.

If any write fails, report the exact error and which actions completed — do not silently retry with variations (per the troubleshooting standard).

## Step 7: Report

Summarize what was published: the vote cast, whether the overview comment went up, how many inline finding-comments were posted (and on which files/lines, with any that failed), **how many findings were demoted to top-level comments and why** (file not in the diff, cited line not on the right side, no line at all, no diff file set), and whether a reviewer-add was needed. Also state the thread status used and what `VOTE` it was derived from, since that determines whether the review blocks completion. Restate any caveat from earlier (non-active PR state, deep-review 🎯 context). Keep it to a few lines.

## Notes

- **Never** post to the PR before Step 5 approval. The review in Step 2 is read-only reconnaissance; the writes are Step 6 only.
- Secrets seen in the diff are read-only context — never echo them into the PR comment (see global Secret Handling standard).
- This skill does not triage or reply to *existing* reviewer threads — it publishes your own review. Handle back-and-forth replies manually or with a follow-up skill.
- One PR per invocation. To review several, run `/review-pr` once per PR so each gets its own confirmation gate.
