# corporate

A Claude Code plugin that renders all assistant prose in **corporate jargon**
(management-consultant / big-tech all-hands register) while leaving code,
identifiers, file paths, command output, and any backtick-wrapped content
verbatim.

## Install

```
/plugin marketplace add TimZander/claude
/plugin install corporate@tzander-skills
```

## Activate

The skill activates and persists for the whole session when you say any of:

- "talk like a consultant", "corporate mode", "corporate jargon", "buzzword mode"
- "let's synergize"
- or it loads automatically if a repo's `CLAUDE.md` instructs always-on use

On activation it announces the active flavor and how to switch or stop, then
applies the register to every turn until you say "stop corporate" / "end
corporate mode" / "speak plainly".

## Flavors

| Flavor | Voice |
|---|---|
| `synergist` (default) | Smooth middle-management buzzword fluency — clear, collaborative, jargon-rich |
| `executive` | C-suite gravitas — measured, terse imperatives, ownership language |
| `hype` | Startup all-hands / sales-pitch energy — exclamatory and relentlessly upbeat |
| `mission` | `synergist` during work + a three-line haiku (5–7–5) on task completion |

Switch any time: "executive flavor", "hype flavor", "mission flavor", etc.

## What stays in plain English

Content inside backticks and code fences is **always** preserved verbatim
(a hard rule). Commit messages, PR descriptions, code comments, safety
warnings, and error text are preserved by default and individually
configurable in
[`skills/corporate/corporate.config`](skills/corporate/corporate.config).

## Files

- [`skills/corporate/SKILL.md`](skills/corporate/SKILL.md) — the skill definition
- [`skills/corporate/examples.md`](skills/corporate/examples.md) — extended before/after corpus
- [`skills/corporate/corporate.config`](skills/corporate/corporate.config) — flavor + preservation toggles

## Guardrail

The register is a caricature of generic meeting-speak — it never mocks real
people or companies, never uses jargon with insensitive origins
("open the kimono", "drink the Kool-Aid", "blacklist/whitelist", "tribe", …),
and always yields to plain English when buzzwords would obscure a fact the
user needs to act correctly.
