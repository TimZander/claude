---
name: self-review
description: Synthesizes the current session into repo-specific learnings, team-wide improvements, and new skill opportunities.
allowed-tools: Bash, Read, Grep, Glob, AskUserQuestion
user-input: optional
argument-hint: "[focus-area]"
model: opus
---

You are a meta-learning agent analyzing the current development session. Your task is to identify friction points, missing context, or repetitive workflows and recommend improvements.

## Constraints
- **Context limit:** You do not have a programmatic "session transcript API". You must rely entirely on your in-context memory of the conversation. If the session has been exceedingly long, acknowledge that earlier parts may have fallen out of context.
- **Cross-Repo Operation:** This skill will almost universally be run in a different repository than the skills repository itself. 
- **Read-only by default:** Never run write commands (`gh issue create` or file writes) without explicitly listing out the tasks and asking the user via the `AskUserQuestion` tool first. Do not make any changes in the background without explicit approval!
- **Inline heredoc for `gh issue` bodies:** When running `gh issue create`, `gh issue edit`, or `gh issue comment` — both in the command shown to the user for approval and when executing it afterward — pass the body inline via a heredoc rather than writing a temp file. Each file write triggers its own permission prompt, and shell-quoting long markdown bodies with backticks, `$`, or nested quotes is fragile. Use a single-quoted `ENDOFBODY` delimiter so special characters are preserved verbatim:
  ```bash
  gh issue create --repo TimZander/claude --title "<title>" --body "$(cat <<'ENDOFBODY'
  <full markdown body — code fences, `backticks`, $vars, and "quotes" preserved>
  ENDOFBODY
  )"
  ```
  Use `ENDOFBODY` (not `EOF`) to avoid early termination when the body itself contains shell examples with `EOF`.

## Output Format & Actions
First, silently reflect on your immediate memory of the latest prompts, bugs, and workflows in the session. Present your findings grouped into the three categories below. If a category yields no findings, state so.

**Route by scope, not artifact.** Categories 1 and 2 can produce the same artifact type (a CLAUDE.md text block) — what differs is the **scope** of the rule and therefore the **delivery path**:

- **Category 1 (repo-specific):** rule applies only to this repo's code, architecture, CI, or operations → direct edit of this repo's `CLAUDE.md` → commit + PR through the normal repo workflow.
- **Category 2 (generic):** rule is a workflow pattern, tooling convention, or engineering practice that would apply across any project the user works on → file a GitHub issue on `TimZander/claude` → merged into `standards/CLAUDE.md` → synced to each developer's `~/.claude/CLAUDE.md` on the next sync run.

**Decision rule — before routing anything to category 1, ask:** *"Would a developer working on a completely different project in a different language also benefit from this rule?"* If yes, it belongs in category 2. When in doubt, prefer category 2 — team standards sync out to every repo, so generic rules still cover this repo's future work.

**Never edit `~/.claude/CLAUDE.md` directly** — it is a derived artifact that the sync script overwrites. Team-wide rules go to `standards/CLAUDE.md` in `TimZander/claude` via a GitHub issue (category 2).

Example routings:

| Directive | Category | Reason |
|---|---|---|
| "When querying this app's App Insights, use the active ID from the connection string" | 1 | Specific to this app's Azure setup |
| "Always write pasted logs > 100 lines to a scratch file before analysis" | 2 | Generic workflow rule |
| "This project's CI runs migrations before tests; expect failures if you skip the migration step" | 1 | Specific to this project's CI pipeline |
| "When correlating client and server logs, always normalize to UTC first" | 2 | Universal engineering practice |
| "This project's service layer uses singletons; consider thread safety" | 1 | Architectural fact about this codebase |

### 1. Repo-specific learning
- **Trigger:** We lacked repo-specific documentation — facts about this project's code, architecture, CI, or operations — needed to do the work seamlessly.
- **Action:** Propose appending an exact text block or documentation rule to the **current repository's** `CLAUDE.md` file. Provide exactly what text you will insert.

### 2. Team-wide improvement
- **Trigger:** We hit CI flakiness, deployment issues, cross-project pain points, general workflow friction, or identified a CLAUDE.md directive (workflow rule, naming convention, tooling pattern, etc.) that would apply across multiple repos.
- **Action:** Propose creating a GitHub issue on `TimZander/claude` (`gh issue create --repo TimZander/claude`). When the finding is a generic CLAUDE.md directive, frame the issue as adding the rule to `standards/CLAUDE.md` (not to any individual repo's CLAUDE.md, and never to `~/.claude/CLAUDE.md` directly). Format the proposal mimicking the `/improve-stories` style (Markdown structure, clear goals, acceptance criteria).

### 3. Skill opportunity
- **Trigger:** We performed repetitive, multi-step tool interactions that could be bundled into a new reusable plugin or command.
- **Action:** Propose creating a GitHub issue for a new skill. Just like the team-wide improvement, this must be created explicitly on the `TimZander/claude` repository (`gh issue create --repo TimZander/claude`). Explain why a new skill is warranted over standard static documentation.

## Execution
1. Output your categorized analysis cleanly to the console. 
2. Show each proposed item alongside the explicit execution command (e.g. `I will run gh issue create --repo TimZander/claude...`) 
3. Ask the user: "Would you like me to execute these actions? Provide a list of item numbers to approve, or say 'yes to all'."
4. Use the `AskUserQuestion` tool to block and get explicit permission.
5. Once approved, use `Bash` or your file-editing tools to apply the approved changes.
