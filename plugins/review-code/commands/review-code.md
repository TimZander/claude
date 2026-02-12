---
name: review-code
description: Perform a critical code review of all changes on the current branch compared to main
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob
---

You are performing a rigorous code review of all changes on the current branch compared to main. Your job is to find problems, not to be agreeable.

## Step 1: Gather Context

**Run all of these in parallel** to minimize latency:

1. Run in one Bash call: `git fetch origin main && git log origin/main..HEAD --oneline && git diff origin/main...HEAD --stat`
2. Run in a separate parallel Bash call: `git diff -U10 origin/main...HEAD` (10 lines of context around each change)
3. Read the project's `CLAUDE.md` (if it exists) to understand project-specific coding standards.

The diff with context is your primary input. Only Read a full file when you need more surrounding context to understand a specific change — do not read every changed file upfront.

When you do need to read files or grep for references (Steps 6-8), **make parallel tool calls** whenever the reads are independent of each other.

## Step 2: Review Mindset

- **Default to skepticism.** Assume there are problems until you've proven otherwise.
- **Read every line of the diff.** Don't skim. Understand what each change does and why.
- **Review what's NOT there.** Missing error handling, missing tests, missing edge cases, and missing documentation are all defects.
- **Question the premise.** Before reviewing the implementation, ask: is this the right thing to build? Does it actually solve the stated problem? Could the problem be solved without code changes at all?

## Step 3: Feature Fitness

- **Does this solve the actual problem?** Restate the problem in your own words based on the branch name, commit messages, and code changes. Then check if the implementation addresses it. Flag if the solution solves a different or broader problem than what was asked for.
- **Is anything unnecessary?** Flag abstractions, configurability, extensibility points, or helper methods that serve no current requirement. Every line of code is a liability.
- **Would a simpler approach work?** If a 5-line change could replace a 50-line change, say so. Propose the simpler alternative concretely.
- **Is this the minimal change?** Check for scope creep: wholesale refactoring of unrelated code, added features that weren't requested, or large structural changes unrelated to the goal. However, **small, clear improvements to files already being touched are encouraged** — see the "Leave It Better" section below.

## Step 4: Complexity and Maintenance Burden

For every change, explicitly assess:

- **Does this increase, decrease, or maintain the current complexity?** State which and why.
- **New concepts introduced:** Does this add new patterns, abstractions, services, or conventions that the team must now understand and maintain?
- **Dependency impact:** Does this add new dependencies, or increase coupling between existing components?
- **Future maintenance cost:** Will this require ongoing attention? Does it create something that can silently break or drift out of sync?
- **Readability:** Could a developer unfamiliar with this code understand it without explanation? If not, the code is too clever.

## Step 5: Leave It Better

When touching a file, the author should leave it better than they found it. Check whether the changed files have nearby opportunities for clear, concise improvements. These are **encouraged** and should be called out if missing:

- **Explicit types.** Are variable types, return types, or parameter types implicit where they could be explicit?
- **Dead code.** Are there unused imports, unreachable branches, commented-out code, or unused variables in the changed files?
- **Style consistency.** Does the changed code match the surrounding style? Are there inconsistent naming conventions, spacing, or formatting in the same file?
- **Clarifying comments.** Is there non-obvious logic that would benefit from a brief comment? Conversely, are there stale or misleading comments that should be updated or removed?
- **Naming.** Are variable, method, or class names clear and accurate? A rename in a touched file is a welcome improvement.
- **Performance.** Correctness and readability come first, but flag obvious performance issues: unnecessary allocations in hot paths, O(n²) when O(n) is straightforward, repeated expensive operations that could be cached, missing pagination on unbounded queries, or blocking calls where async is expected. Don't suggest micro-optimizations that hurt readability.
- **Logging.** From the diff context, identify the logging pattern used in the codebase (e.g., `logger`, `console.log`, `Log.`, `logging.`, `slog.`). Only Grep if the pattern isn't visible in the diff. Then check: does the changed code log appropriately? Are error paths logged? Are key operations traceable? Does the log level match the codebase conventions (debug vs info vs warn vs error)? If the surrounding codebase has logging but the changed code does not, flag it. Even if the project has no logging at all, suggest adding it when the changed code touches precarious areas: payment/billing, authentication, data mutations, external API calls, scheduled jobs, or anything where silent failure would be costly to debug in production. Flag any caught exceptions that are swallowed silently (empty catch blocks, catch-and-continue with no logging or re-throw) — these hide bugs and make production issues nearly impossible to diagnose.

**Boundaries:** These improvements should be limited to files already being modified and should be clear, concise, and obviously correct. Wholesale refactoring of unrelated code, large structural changes, or changes that require extensive testing are not in scope here.

If the author made good opportunistic improvements, acknowledge them. If obvious opportunities were missed in touched files, list them under "Improvement Opportunities" in the output.

## Step 6: Unintended Consequences

- **Trace all callers and consumers.** If a method signature, return type, or behavior changed, verify every call site still works correctly. Grep for references only when a public API actually changed — don't grep for every function touched.
- **Check for state mutations.** Does this change shared state, static fields, singleton behavior, or cached data in ways that affect other code paths?
- **Consider timing and ordering.** Does this change when something executes? Could it create race conditions, deadlocks, or ordering dependencies?
- **Check boundary conditions.** What happens with null inputs, empty collections, first run, network failure, concurrent access, or maximum data volumes?
- **Platform impact.** If the change touches shared code, verify it works correctly on both Android and iOS. If it touches platform-specific code, verify the other platform's equivalent is still consistent.

## Step 7: Breaking Changes

Specifically check whether this change breaks any existing contract or consumer:

- **Public API changes.** Were any endpoints removed, renamed, or did their request/response shape change? Check route definitions, controller signatures, and DTO/model classes.
- **Shared interface changes.** Were any public method signatures, return types, or parameter types changed on classes/interfaces consumed by other modules or services?
- **Contract/schema changes.** Were any serialized formats changed (JSON field names, event payloads, message queue contracts, gRPC/protobuf definitions)?
- **Configuration changes.** Were any environment variables, config keys, or feature flags renamed, removed, or given new semantics?
- **Behavioral changes.** Does existing functionality now behave differently in a way callers depend on? (e.g., a method that returned null now throws, ordering of results changed, default values changed)
- **Database assumptions.** Does the code now reference new or altered tables, columns, or stored procedures that other services may also consume?

If you find breaking changes, Grep for usages of the changed API/contract to assess the blast radius. Each breaking change must be flagged as 🔴 in the Findings with a clear description of what broke and who is affected.

## Step 8: Assumptions Audit

List every assumption the code makes. Then verify each one:

- Does this assume data will always be in a certain format?
- Does this assume a service will always be available?
- Does this assume a certain execution order?
- Does this assume non-null values without checking?
- Does this assume collection sizes or string lengths?
- Does this assume API responses won't change?

Flag assumptions that weren't validated. If the code assumes something that could reasonably be false, it needs either validation or a comment explaining why the assumption is safe.

## Step 9: Test Coverage

- **Are there tests?** If not, why not? "It's hard to test" is not an acceptable reason — it usually means the code needs restructuring.
- **Do tests cover the actual behavior change?** Tests that pass regardless of whether the feature works are worthless.
- **Are edge cases tested?** Null inputs, empty data, error conditions, boundary values, concurrent scenarios.
- **Are negative tests included?** Tests that verify the code correctly rejects invalid input or handles failure gracefully.
- **Do existing tests still pass?** A change that breaks existing tests is a red flag that the author may not understand the system's contracts.
- **Is the test testing implementation or behavior?** Tests coupled to implementation details are brittle. Tests should verify observable behavior.

## Step 10: Output

**IMPORTANT: You MUST use the EXACT output format below. Do NOT use numbered lists, do NOT create sections like "Critical Issues" or "Assumptions to Verify". Every finding goes in ONE flat list under "Findings" with emoji prefixes. Copy the structure exactly.**

**IMPORTANT: Use actual Unicode emoji characters (🔴 🟡 💡 ✅ ⬜), NOT markdown shortcodes (:red_circle:, :yellow_circle:, etc.).**

Here is the exact template — follow it precisely:

---

## ⚖️ Verdict

**REQUEST CHANGES** / **APPROVE** / **NEEDS DISCUSSION**

## 📋 Summary

One paragraph restating what this change does and whether it achieves its goal.

**Complexity:** Increases / Decreases / Neutral — with brief justification.

## 🔍 Findings

🔴 `path/to/file.ts:42` — Description of critical issue (must fix before merge)
🔴 `path/to/file.ts:55` — Another critical issue
🟡 `path/to/file.ts:78` — Warning: potential bug or maintenance issue
🟡 `path/to/other.ts:12` — Another warning
💡 `path/to/file.ts:90` — Suggestion: optional improvement
✅ `path/to/file.ts:30` — Something done well (use sparingly)

Rules:
- Every finding from ALL review steps goes here: correctness, security, breaking changes, assumptions, unintended consequences, performance, logging, style, naming, simplification — everything.
- Each finding is ONE line: emoji, backtick-wrapped file:line, em dash, description.
- Group findings by file when multiple findings affect the same file.
- If there are no findings, write "No issues found."
- Do NOT create separate sections for different finding types.

## 🧪 Test Gaps

⬜ Scenario that needs a test
⬜ Another scenario that needs a test

If coverage is adequate, write "Coverage is adequate."

## ⚡ Bottom Line

2-3 sentences. Restate the verdict, count of 🔴/🟡/💡 findings, and the single most important thing the author should address.
