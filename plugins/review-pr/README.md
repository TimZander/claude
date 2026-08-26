# review-pr

End-to-end **Azure DevOps** pull request review, in one pass: summarize the PR, delegate the
critical review to [`deep-review`](../deep-review), then post your feedback back to the PR —
inline comments plus a vote — **only after you confirm the exact plan**.

This is the "respond to a PR" companion to `deep-review`. `deep-review` finds the problems;
`review-pr` wraps it with the ADO plumbing to summarize, gate, and publish your review.

> **ADO only.** This plugin publishes to Azure DevOps pull requests. For GitHub PRs, use
> `/deep-review` then GitHub's built-in `/review`.

## Usage

```
/review-pr pr 4846                    # review + draft a response for PR 4846 in the current repo
/review-pr pr 4846 focus on threading # forward a focus area to deep-review
/review-pr <ADO PR URL>               # full URL, e.g. https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/4846
/review-pr pr 4846 base:develop       # non-default base branch (forwarded to deep-review)
```

A PR reference is **required** — the plugin publishes *your* review to a specific PR, so it
refuses to run against `HEAD`. `#<N>` is an ADO work item, never a PR, and is rejected as a
selector.

> **Run `/clear` first.** A review should start from a clean context. A skill can't clear its
> own context, so this is a habit for you: `/clear`, then `/review-pr pr <N>`.

## Flow — two gates, nothing published until you approve

1. **Confirm the target** — resolve the PR (repo GUID, project, id), print a short read-only
   summary with code highlights, then **gate**: ask before starting the review.
2. **Review** — delegate the full critical review to the `deep-review` skill (which checks out
   the PR's source branch, runs its parallel subagents, and restores your ref afterward).
3. **Draft** — turn deep-review's verdict into an optional overview comment, a numbered list of
   findings you pick from, and a recommended vote.
4. **Confirm** — show the exact plan and **wait**. You choose which findings post as inline
   comments and whether to cast the vote.
5. **Publish** — only after you say go: post the overview + your selected findings as inline
   comments anchored to `file:line`, and cast the vote (which auto-adds you as a reviewer).
   A finding whose file isn't in the PR diff — or whose line isn't on the diff's right side —
   is posted as a top-level comment instead, since ADO would otherwise bury it in the Overview
   tab. The plan flags those before you approve it.

The Step 1b summary only *fetches* refs — it never changes your working directory. The checkout
happens inside `deep-review` in Step 2, after the first gate.

## Verdict → vote mapping

deep-review's verdict plus the 🔴/🟡/💡 counts map to one recommended ADO vote —
`Approved`, `ApprovedWithSuggestions`, `NoVote`, `WaitingForAuthor` or `Rejected`. The
mapping table lives in **Step 4 of [`commands/review-pr.md`](commands/review-pr.md)** and
is deliberately kept in one place: two copies of it drifted apart once already.

The vote is always a recommendation you confirm or override at the gate — never a silent choice.

## Requirements

- An **Azure DevOps** `origin` remote.
- The [`deep-review`](../deep-review) plugin installed (this plugin delegates the actual review to it).
- The `azure-devops` MCP server connected — `review-pr` loads its tools on demand via `ToolSearch`
  and uses them for PR lookup, comment threads, and the vote. If the server is not connected the
  command stops at Step 1 and says so, rather than improvising tool calls.

## Invocation

`review-pr` is **user-invoked only** (`disable-model-invocation: true`). Unlike `deep-review`,
which is read-only and safe for an agent to reach for, this command writes comments and a vote
onto someone else's pull request — so it is never auto-selected by a model. Run it yourself:

```
/review-pr pr 4846
```

An agent that wants the analysis without the publish path should invoke `deep-review` instead.
