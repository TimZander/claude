# Self-Review Plugin

The `/self-review` skill initiates a reflection process where Claude evaluates its current session for missing documentation, team-wide workflow gaps, or potential new skills. 

## Design
Claude is notoriously forgetful from session to session. To bootstrap better tooling, we use `/self-review` when finishing an ad-hoc session to extract insights from the immediate context window. 

This plugin prompts Claude to analyze the recent session and route the findings into actionable tasks:
- **Repo-specific insights:** Written directly to the LOCAL repository's `CLAUDE.md`.
- **Team-wide standards & Skill opportunities:** Created as GitHub issues explicitly tracked over on the `TimZander/claude` repository.

## Usage
`> /self-review [optional focus area]`
