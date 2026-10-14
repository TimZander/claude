# Spec-driven development environment

This environment is for spec-driven development with OpenSpec and the sdd plugin (`/sdd:*`
skills).

- **Follow the repository's workflow.** Read `.claude/sdd-workflow.md` (imported by the repo's
  `CLAUDE.md`) before changing anything, and follow its flow for every change, including its
  rules for recording decisions as ADRs.
- **A repository without sdd: ask, don't set it up.** If there's no `.claude/sdd-workflow.md`,
  tell the owner the repository isn't set up for spec-driven development and ask what they want.
  Never run `/sdd:init` unasked: setting up a repository is the owner's decision.
- **Use the sdd reviews.** `/sdd:spec-review` for the spec, `/sdd:conformance-review` for the
  code, and what the workflow adds for high-risk changes.
