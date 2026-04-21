# Team Coding Standards

These standards are automatically synced into each developer's `~/.claude/CLAUDE.md`
via the sync scripts at the repository root. Team settings (`standards/settings.json`)
are also synced into `~/.claude/settings.json`. Edit these files to update the team's
standards, then have each developer re-run the sync script.

## Naming Conventions

- Use `x` as the variable name for simple lambda expressions
- Only one type per file, except DTO classes may remain in the same file as their associated non-DTO class

## Formatting and Style

- Always use curly braces for `if` statements, even for single-line bodies
- Prioritize code readability and maintainability

## Patterns to Prefer

- Use `is null` instead of `== null`
- Prefer `using` statements over fully qualified type names

## Patterns to Avoid

- Do not use type aliases unless absolutely necessary

## Language-Specific Rules

### C#

- Always use explicit types instead of `var` unless the type is immediately obvious from the right side of the assignment
- Use `string.Empty` instead of `""`
- Prefix private fields with `_` and use camelCase (e.g., `_connectionString`, `_logger`)

## Unit Test Standards

These standards cover unit tests only.

## Smoke Test Standards

**Definition:** A smoke test is the absolute minimum automated check required to prove that a deployed application is online, reachable, and fundamentally functional. It does not verify correctness; it verifies availability.

### When to write smoke tests

- **All web applications:** Every deployed web application is required to have at least one smoke test.
- **API endpoints:** Key API routes should have smoke tests that verify they respond with the expected status code.

### How to write smoke tests

- Smoke tests should be simple, fast, and focused on "is it running?" — no business logic verification.
- Use HTTP calls to verify endpoints respond (primarily status code checks, not payload validation).
- Smoke tests must be idempotent and safe to run against any environment (strictly no data mutations).
- Keep them in a dedicated test project or script (e.g., `*.SmokeTests` or a pipeline script).

**Example (bash/curl):**
```bash
# Good: Only checking if the API is reachable and returning 200 OK
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" https://api.environment.com/health)
if [ "$HTTP_STATUS" -ne 200 ]; then
  echo "Smoke test failed: API returned $HTTP_STATUS"
  exit 1
fi
```

### Pipeline integration

- Smoke tests should be added as a post-deployment step in CI/CD pipelines. They run post-deployment, not during the build phase.
- If a smoke test fails, the pipeline should report the failure (and optionally trigger a rollback if the pipeline supports it).

### When to write unit tests

- **New functionality:** All new code that contains logic (conditionals, calculations, transformations) must have accompanying tests
- **Bug fixes:** Every bug fix must include a test that reproduces the bug and verifies the fix — this prevents recurrence
- **Refactoring:** Before refactoring existing code that lacks test coverage, add tests for the current behavior first, then refactor. This prevents silent regressions.
- **Exceptions:** Tests are not required for:
  - Pure configuration changes, documentation, and prompt/skill templates
  - Simple pass-through wiring (e.g., DI registration)
  - UI-specific code that cannot be unit tested (e.g., view layouts, animations, platform-specific rendering)
  - Code where creating a test fixture would require disproportionate effort relative to the risk — use judgment, but document why tests were skipped in the PR description

### How to write unit tests

- Use the Arrange/Act/Assert pattern with comment separators
- Name tests as `MethodName_Scenario_ExpectedBehavior`
- No magic numbers — extract numeric literals into named `const` locals at the top of each test method
- Keep constants local to each test, not shared at the class level — each test should be readable in isolation
- Cover edge cases: partial state changes, error/exception propagation, no-op when inputs are unchanged
- Include at least one negative test (invalid input, failure scenario) per method under test
- Tests should verify observable behavior, not implementation details

## Integration Test Standards

### When to write integration tests

- **Database access:** When new or modified code reads from or writes to a database, add integration tests that run against a real database (not mocks) to verify queries, mappings, and constraints.
- **New functionality with data layer changes:** Any new repository methods, stored procedure calls, or schema-dependent logic should have integration tests.
- **External API access:** This decision is team-decided per project. Some teams prefer contract/mock tests for external APIs; others prefer live integration tests in a staging environment.

### How to write integration tests

- Use a dedicated test project (e.g., `*.IntegrationTests`). Do not mix integration tests into unit test projects.
- Tests should be **isolated**: each test should set up its own data and clean up after itself (or use transactions that roll back).
- Use the same Arrange/Act/Assert pattern as unit tests, and name tests with the identical convention: `MethodName_Scenario_ExpectedBehavior`.
- Integration tests must be assigned a different test category or trait so they can be separated from unit tests in CI and run on different schedules or against different environments.

## End-to-End (E2E) Test Standards

### When to write E2E tests

- **Core User Journeys:** Every web application must have E2E tests covering its critical paths (e.g., login, primary data submission, checkout flows).
- **Per-Project Basis:** E2E frameworks and specific testing targets are maintained per project. Teams may choose the framework that best fits their needs (e.g., Playwright, Selenium, Cypress).

### How to write E2E tests

- Treat E2E tests as black-box tests. They should interact with the application strictly through the rendered DOM (clicking buttons, filling inputs) rather than testing internal implementation state.
- Ensure E2E tests are resilient by relying on unique accessibility roles, data attributes (`data-testid`), or labeled text. **Avoid targeting fragile CSS selectors or dynamic layout classes.**
- Tests should clean up their own state or run in isolated sandbox environments (like Playwright browser contexts) to prevent data collision.

### Pipeline integration

- E2E tests should be wired into the CI/CD pipeline to block deployment to production if a critical user journey is broken.
- Depending on the speed of the test suite, E2E tests can run post-deployment in a staging environment before manual sign-off, or against ephemeral preview environments during the PR validation phase.

## Python Plugin Dependencies

Standard pattern for plugins that depend on Python packages at runtime. The pattern must leave the plugin with a single resolved interpreter — call it the **plugin python** — that the rest of the plugin uses for every subsequent `python`/`python3` invocation.

### Resolution cascade

Work through these steps in order. Stop at the first one that succeeds.

1. **Try the system interpreter.** Run `python3 -c "import <deps>"` (fall back to `python` if `python3` is not on PATH — typical on Windows with the python.org installer). If it exits 0, the plugin python is that system interpreter; skip to **Verify**.

2. **Install with `uv` into the system interpreter.** If `command -v uv` succeeds, run `uv pip install --system <packages>`. On most systems this bypasses PEP 668 (`externally-managed-environment`) restrictions. If it fails with an externally-managed error, retry with `uv pip install --system --break-system-packages <packages>`. On success, the plugin python is still the system interpreter.

3. **Fallback: disposable user-local venv.** Use a user-isolated, OS-portable temp location and probe for the right interpreter path:
   ```bash
   VENV_DIR="${TMPDIR:-/tmp}/<plugin-name>-venv-$(id -u 2>/dev/null || echo default)"
   [ -d "$VENV_DIR" ] || python3 -m venv "$VENV_DIR" || python -m venv "$VENV_DIR"
   # venv interpreter lives at different paths on Unix vs Windows — probe for whichever exists
   if   [ -x "$VENV_DIR/bin/python" ];        then PLUGIN_PY="$VENV_DIR/bin/python"
   elif [ -x "$VENV_DIR/bin/python3" ];       then PLUGIN_PY="$VENV_DIR/bin/python3"
   elif [ -x "$VENV_DIR/Scripts/python.exe" ];then PLUGIN_PY="$VENV_DIR/Scripts/python.exe"
   fi
   "$PLUGIN_PY" -m pip install <packages>
   ```

4. **Verify.** Run `<plugin python> -c "import <deps>"` and confirm it exits 0 before proceeding. If it fails, report the error and stop — do not fall through to the main plugin flow with broken imports.

### Notes

- The venv directory name includes `$(id -u)` so users sharing a host don't collide on the same path (and so permission errors don't appear on re-runs by a different user).
- `${TMPDIR:-/tmp}` works on macOS (per-user `/var/folders/...`), Linux (typically unset, falls back to `/tmp`), and Windows Git Bash (`/tmp` maps to the user's temp). On native Windows shells, substitute `$env:TEMP`.
- Venv interpreter paths differ by OS: `bin/python` on Unix/macOS, `Scripts/python.exe` on Windows — always probe, never hard-code.
- The venv is disposable: `/tmp` self-cleans on reboot, and `pip install` is idempotent (`already satisfied` is a fast no-op), so re-runs are cheap.
- `uv pip install --system` does not work on every managed Python without `--break-system-packages`; treat it as "preferred but not guaranteed" and always fall through to the venv on non-zero exit.

### Convention for plugin authors

Plugin command markdown should embed the resolution cascade above as an early step (adapted for the plugin's specific dependency list) and refer to the resolved interpreter by a stable name (e.g., `PLUGIN_PY` or "the plugin python") in every subsequent script-execution step.

## Agent Compatibility

These standards and skills (`plugins/`) are configured for the Claude Code toolchain (`.claude-plugin/marketplace.json`) but can be compiled into Google **Antigravity** skill format using a translation script.

- **To compile Claude plugins into Antigravity `SKILL.md` structures**, run `python scripts/antigravity-sync.py`.
- This compiles and symlinks plugin sources to `.agent/skills/<name>`.
- **DO NOT** manually edit files in `.agent/skills/`. They are overwritten on compilation. Edit the primary sources in `plugins/`!

## Model Selection and Token Efficiency

### Task-to-model mapping

**Opus — deep reasoning required:**
- Code reviews (`/deep-review`) — multi-file analysis, security auditing, architectural assessment
- Large refactors spanning multiple files or changing public APIs
- Story improvement (`/improve-stories`) — codebase research + structured writing
- Complex debugging requiring cross-module reasoning

**Sonnet — standard development work:**
- Feature implementation with clear requirements
- Bug fixes with a known root cause or small scope
- Writing tests for existing code
- Documentation changes with codebase research

**Haiku — mechanical or formulaic tasks:**
- Generating commit messages, PR descriptions (`/craft-pr`, `/craft-commit`)
- Simple file lookups, formatting, renaming
- Staging commands (`/craft-stage`)
- Subagent work with narrow, well-defined prompts (e.g., "fetch this issue and return the body")

*Note: Model selection is a guideline, not a hard rule. Complex edge cases may need escalation to a more capable model.*

### Context vs. Token Savings

- Never sacrifice code context for token savings during a deep review. Quality and architectural verification require full file context.
- Reserve token-aggressive strategies (like diff-only analysis) for mechanical summarization tasks (e.g., commit messages, PR descriptions).
- Constrain subagent outputs: When writing prompts for intermediate subagents or plugins, ask the LLM to return succinct formats (like IDs, line numbers, or booleans) instead of conversational explanations to minimize expensive output tokens.

## Tool Usage

- Prefer core tools (e.g., Read, Edit, Write, Grep, Glob, Agent, Bash) over MCP or other tools that require permission prompts — minimize interruptions to maximize velocity
- When core tools are insufficient or significantly less efficient, external tools and custom scripts (Python, etc.) are acceptable
- If a particular external tool or workflow pattern is used repeatedly across multiple sessions, suggest creating a skill to wrap the common usage
- **ADO MCP: always resolve repository GUIDs before creating PRs.** `repo_create_pull_request` requires a repository GUID for `repositoryId` — passing a name or `Project/Name` produces misleading errors. Call `repo_get_repo_by_name_or_id` first to resolve the name to a GUID.

## Troubleshooting Failures

When a deployment, infrastructure operation, or third-party integration fails with an unexpected error:

- **Do not retry the same operation with variations.** If it failed twice with the same error, a third attempt with slightly different flags won't help.
- **Search for known issues first.** Before diagnosing further, search GitHub issues, Stack Overflow, and vendor docs for the exact error message or platform/version combination. This takes seconds and often surfaces known bugs or unsupported configurations.
- **State your confidence level.** If speculating about a root cause, say so explicitly rather than presenting it as a conclusion. "I suspect X but haven't confirmed" is better than "X is the issue."
- **Ask: could this be a known limitation?** Especially with preview/new runtime versions, unsupported plan types, or region availability — these are commonly documented in vendor issue trackers.

## GitHub Issue Relationships

GitHub's "Relationships" feature (Blocked by / Blocking) can be managed via `gh api graphql`.

### Get issue node IDs

Single issue:
```bash
gh api graphql -f query='
query {
  repository(owner: "<OWNER>", name: "<REPO>") {
    issue(number: 123) { id number title }
  }
}'
```

Multiple issues (use aliases — `issues` doesn't support a `numbers` filter):
```bash
gh api graphql -f query='
query {
  repository(owner: "<OWNER>", name: "<REPO>") {
    a: issue(number: 445) { id number title }
    b: issue(number: 446) { id number title }
    c: issue(number: 447) { id number title }
  }
}'
```

### Create "blocked by" relationships

**Schema:** `addBlockedBy(input: { issueId: BLOCKED_ISSUE, blockingIssueId: BLOCKING_ISSUE })`

- `issueId` = the issue that IS blocked (the dependent)
- `blockingIssueId` = the issue that BLOCKS it (the dependency)

Single relationship (e.g., #446 is blocked by #445):
```bash
gh api graphql -f query='
mutation {
  addBlockedBy(input: {
    issueId: "<NODE_ID_OF_446>"
    blockingIssueId: "<NODE_ID_OF_445>"
  }) {
    issue { number title }
  }
}'
```

Batch — multiple relationships in one mutation (use aliases):
```bash
gh api graphql -f query='
mutation {
  a: addBlockedBy(input: { issueId: "<ID_446>", blockingIssueId: "<ID_445>" }) { issue { number } }
  b: addBlockedBy(input: { issueId: "<ID_447>", blockingIssueId: "<ID_445>" }) { issue { number } }
}'
```

### Remove relationships

```bash
gh api graphql -f query='
mutation {
  removeBlockedBy(input: {
    issueId: "<NODE_ID_OF_BLOCKED_ISSUE>"
    blockingIssueId: "<NODE_ID_OF_BLOCKING_ISSUE>"
  }) {
    issue { number }
  }
}'
```

### Query existing relationships

```bash
gh api graphql -f query='
query {
  repository(owner: "<OWNER>", name: "<REPO>") {
    issue(number: 447) {
      number
      title
      blockedBy(first: 10) { nodes { number title } }
      blocking(first: 10) { nodes { number title } }
    }
  }
}'
```

Batch — verify relationships across multiple issues:
```bash
gh api graphql -f query='
query {
  repository(owner: "<OWNER>", name: "<REPO>") {
    a: issue(number: 446) { number blockedBy(first: 5) { nodes { number title } } }
    b: issue(number: 447) { number blockedBy(first: 5) { nodes { number title } } }
    c: issue(number: 448) { number blockedBy(first: 5) { nodes { number title } } }
  }
}'
```

### Gotchas

- `issues(numbers: [...])` does **not** exist in the GraphQL schema — use aliases (`a: issue(number: N)`) to batch
- `addBlockedBy` is **not idempotent** — calling it twice for the same pair will error
- Node IDs are opaque strings (e.g., `I_kwDOQOqPc871pGVo`) — always fetch them fresh

## No Attribution

- Never add `Co-Authored-By` trailers, "generated by" footers, or any other attribution metadata to commit messages, PR titles, PR descriptions, issue comments, or any other generated output

## Git Push Safety

- **Never push to `main` or `master`** — all changes must go through pull requests
- **Never force push** (`--force`, `-f`, `--force-with-lease`) to any branch
- **Always create new commits instead of amending** — amending requires force pushing to sync with the remote. When a pre-commit hook fails, fix the issue and create a new commit; do not `--amend` the previous one. Only amend if the user explicitly requests it and acknowledges the force push consequence.

## Commit Email

Each repository should use a consistent commit email that matches its hosting platform's identity:
- **ADO repos:** Use the email matching your Entra ID (AAD) identity — this is what the ADO web interface uses for commits and what ADO matches for licensing attribution
- **GitHub repos:** Use the email associated with your GitHub account

The global `pre-commit` hook enforces this when a `.commit-email-rules` file exists in the repo root. Add this file to any repo that needs enforcement:
```
# .commit-email-rules
domain=example.com
```

To configure email automatically, use `includeIf` in `~/.gitconfig`. Two approaches:

**By remote URL (recommended, Git 2.36+)** — matches based on the remote origin, no directory reorganization needed:
```gitconfig
[includeIf "hasconfig:remote.*.url:https://dev.azure.com/<ORG>/**"]
    path = ~/.gitconfig-work
[includeIf "hasconfig:remote.*.url:git@ssh.dev.azure.com:**/<ORG>/**"]
    path = ~/.gitconfig-work
```

**By directory** — requires repos grouped under a common parent:
```gitconfig
[includeIf "gitdir:~/work/"]
    path = ~/.gitconfig-work
```

Then in `~/.gitconfig-work`:
```gitconfig
[user]
    email = yourname@your-work-domain.com
```

Add all email variants as alternate emails in your ADO profile (User Settings > General > Emails) so historical commits from other addresses are attributed correctly.

## Git Hygiene Before New Work

Before starting any new unit of work (picking up an issue, beginning a task that will produce code changes), verify the local git state:

1. Run `git status` to check the current branch and working tree
2. If not on `main`, switch to `main` (stash uncommitted changes if needed)
3. Run `git fetch origin main` and compare local `main` to `origin/main`
4. If local `main` is behind, run `git pull` to catch up
5. Create a new branch from the up-to-date `main`

Do not start work on an existing feature branch unless the user explicitly asks to continue work on that branch.

## Mark Work Items Active

After creating the feature branch but before any code research or changes, update the work item state:

- **GitHub Issues:** Self-assign with `gh issue edit <number> --add-assignee @me`
- **ADO work items:** Move state to Active using the appropriate update tool

**Exceptions — do NOT change state when:**
- Improving/grooming stories (e.g., `/improve-stories`)
- Reviewing or reading an issue without starting implementation
- The user explicitly says not to change state

## Pre-PR Checklist

When asked to push a branch or create a pull request, remind the user to run `/deep-review` on the current branch if they haven't already done so during this session. Keep the reminder to a single sentence — do not block the push or PR. Do not auto-invoke `/deep-review`; always let the user decide.

## Phased Work

When an issue defines phased work (Phase 1, Phase 2, Phase 3), ship each phase as a separate PR — even when the phases feel small. Interaction bugs between phases (e.g., a new tri-state return value meeting existing binary assumptions in callers) only surface when the phases are integrated. Separate PRs catch these incrementally during review instead of requiring multiple fix-up commits after the fact.

<!-- Keep in sync with plugins/deep-review/commands/deep-review.md preamble -->
## Code Review Standards

When reviewing code (PRs, branches, or staged changes), apply rigorous scrutiny. The goal is to catch problems before they ship, not to be agreeable.

- **Default to skepticism** — assume there are problems until proven otherwise
- **Read every line of every diff.** Do not skim. Understand what each change does and why.
- **Review what's NOT there** — missing error handling, tests, edge cases, and documentation are all defects
- **Question the premise** — is this the right thing to build? Could a simpler approach work?
- **Flag unnecessary complexity** — every line of code is a liability; if a 5-line change could replace a 50-line change, say so
- **Trace unintended consequences** — check callers, state mutations, timing, and boundary conditions
- **Audit assumptions** — list and verify every assumption the code makes; flag those without validation
- **Demand test coverage** — "hard to test" means the code needs restructuring, not a pass on testing
