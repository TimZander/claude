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
