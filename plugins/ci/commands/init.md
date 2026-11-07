---
description: Set a repository up with the shared Cloudflare Pages preview and teardown workflows from TimZander/ci-recipes, pinned to a ci-recipes commit
argument-hint: "[Pages project name]"
allowed-tools: Bash, Read, Edit, Glob, Grep
---

# Set up shared CI

Writes `.github/workflows/preview.yml` and `preview-teardown.yml` from ci-recipes'
templates, then fits the preview's build steps to this repository. The rules they follow are
ci-recipes' `STANDARD.md`: the preview deploys alongside the tests and never waits for them,
as `pr-<number>`, with one comment; teardown runs when a PR closes, plus a weekly sweep.

## Find the script

It is `${CLAUDE_PLUGIN_ROOT}/scripts/ci.sh`. If that path still reads literally
`${CLAUDE_PLUGIN_ROOT}` or doesn't exist, Glob for `**/ci/**/scripts/ci.sh` under
`~/.claude/plugins` (resolve `~` first), skip candidates whose plugin folder has a
`.orphaned_at` marker, and take the first that remains. Below, `<ci>` means `bash <that path>`.
Run it from the repository's root.

## Steps

0. **Only when asked.** Moving a repository onto ci-recipes is the owner's decision; run this
   only when they asked for it.
1. **Read what is there.** List `.github/workflows/`. If this repository already deploys
   previews (look for `pages deploy` and `--branch`), say so and ask whether to replace
   them: this is an adoption, not a fresh setup. The script refuses while another workflow
   still deploys a preview, so take the preview deploy out first: delete a preview-only
   workflow and its old teardown, or split the preview job out of a workflow that also
   deploys production (keep production gated on the tests). In an sdd repository, an
   adoption is a change like any other: propose it first, then run these steps from
   `/opsx:apply`.
2. **Gather the three values.** The Pages project name (**$ARGUMENTS**, else from an
   existing `--project-name`, else ask). The build's output directory (from the existing
   deploy or the build config). The **exact** wrangler version: from a lockfile or an
   existing pin; if there is neither, ask, and never use a range.
3. **Write the workflows.** Run `<ci> init --project <name> --wrangler <version> --directory <dir>`.
   Exit 3 means it refused and wrote nothing: report its reason and stop, unless the reason is
   an old preview deploy you were asked to replace (step 1). Exit 1 also wrote nothing.
4. **Fit the build.** Replace the template's `npm ci` / `npm run build` steps in
   `preview.yml` with this repository's real build, copied from its existing deploy
   (setup-node or setup-uv, staging steps, build-time env). Keep `if:`, `concurrency`,
   `permissions` and the ci-recipes step as written. Narrow `on.pull_request.paths` only when
   the site is a part of the repository, and say that a path filter re-fires on every later
   push of a PR that matched it once.
5. **Gate production, not the preview.** If the production deploy does not wait for the tests,
   or the old preview job ran the tests first, say so and fix it: production `needs` the test
   jobs; the preview needs nothing.
6. **Check the secrets.** The workflows need `CLOUDFLARE_API_TOKEN` and
   `CLOUDFLARE_ACCOUNT_ID`. Say so; you can't read secrets, so the owner confirms.
7. **Report** the files written, the pinned commit, what you changed in the build, and what the
   owner checks on the PR: one preview comment, both links working, and, after closing a test
   PR, the comment saying the preview was removed.
