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

The Step 1b summary only *fetches* refs — it never changes your working directory. The checkout
happens inside `deep-review` in Step 2, after the first gate.

## Verdict → vote mapping

| deep-review verdict | Findings | Recommended vote |
|---|---|---|
| APPROVE | only 💡 or none | `Approved` |
| APPROVE | some 💡 worth noting | `ApprovedWithSuggestions` |
| NEEDS DISCUSSION | any | `NoVote` |
| REQUEST CHANGES | 🟡 only | `WaitingForAuthor` |
| REQUEST CHANGES | one or more 🔴 | `WaitingForAuthor` (default), `Rejected` offered |

The vote is always a recommendation you confirm or override at the gate — never a silent choice.

## Requirements

- An **Azure DevOps** `origin` remote.
- The [`deep-review`](../deep-review) plugin installed (this plugin delegates the actual review to it).
- The `azure-devops` MCP server connected — `review-pr` loads its tools on demand via `ToolSearch`
  and uses them for PR lookup, comment threads, and the vote.

## Agent invocation

The command is model-invocable (`disable-model-invocation: false`), so an agent can call it via
the Skill tool:

```
Skill({ skill: "review-pr", args: "pr 4846 focus on error handling" })
```
