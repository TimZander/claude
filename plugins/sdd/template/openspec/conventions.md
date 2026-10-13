# Spec conventions

How specs are written in this repository. Read this before writing or changing a spec.
(Created by sdd-init as a starting point; it belongs to this repository, so edit it freely.)

## Capabilities

- One capability per folder in `openspec/specs/<capability>/spec.md`, named for what it does
  (`checkout`, `export`), not for the code that does it.
- Each spec starts with `## Purpose`: one or two sentences on what the capability is for.

## Requirements

- A requirement states one rule with SHALL. Descriptive text gets no SHALL.
- Every requirement has at least one scenario whose THEN is observable: an output, a file, a
  response, a page, an exit status.
- Scenarios use illustrative data, never values copied from real content that may change.
- Something the owner hasn't decided is not a requirement: it is an open question in the
  change's `design.md`, with the assumption the change proceeds on.

## Changes

- A change carries `proposal.md` (why and scope), its deltas, `design.md` when there are
  decisions or open questions, and `tasks.md`.
- A `MODIFIED` requirement holds the requirement's full text, with every scenario it keeps.
- Tests cite the requirement they verify.

## Project terms

<!-- Terms, IDs and shared rules every spec in this repository uses. -->
