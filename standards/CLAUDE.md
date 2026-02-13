# Team Coding Standards

These standards are automatically synced into each developer's `~/.claude/CLAUDE.md`
via the sync scripts at the repository root. Edit this file to update the team's standards,
then have each developer re-run the sync script.

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

## Test Standards

- Use the Arrange/Act/Assert pattern with comment separators
- Name tests as `MethodName_Scenario_ExpectedBehavior`
- No magic numbers — extract numeric literals into named `const` locals at the top of each test method
- Keep constants local to each test, not shared at the class level — each test should be readable in isolation
- Cover edge cases: partial state changes, error/exception propagation, no-op when inputs are unchanged
- Include at least one negative test (invalid input, failure scenario) per method under test
- Tests should verify observable behavior, not implementation details
