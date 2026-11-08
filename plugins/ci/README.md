# ci

Shared CI for every repository, from [TimZander/ci-recipes](https://github.com/TimZander/ci-recipes).
Its [STANDARD.md](https://github.com/TimZander/ci-recipes/blob/main/STANDARD.md) is the
contract. This plugin is how a repository starts using it and keeps up with it.

## Install

```
/plugin install ci@tzander-skills
```

Cloud sessions on the sdd environment get it from `plugins/sdd/cloud-setup.sh`.

## Commands

| Command | What it does |
|---|---|
| `/ci:init [project]` | Writes `.github/workflows/preview.yml`, `preview-teardown.yml` and `branch-preview.yml` from ci-recipes' templates, pinned to the commit in `scripts/ci-recipes.pin`, then fits the previews' build steps to the repository. Refuses to overwrite. |
| `/ci:update [sha]` | Moves every ci-recipes pin in `.github/workflows/` to one commit (default: ci-recipes' `main`). Refuses a commit that no longer has an action the repository uses. |
| `/ci:minutes <pr>... [--repo OWNER/NAME]` | A pull request's billed Actions minutes: every job rounded up to a whole minute, re-runs and the merge's deploy included. |

## A new repository, from zero

1. Create the repository and add its secrets `CLOUDFLARE_API_TOKEN` (Pages: Edit) and
   `CLOUDFLARE_ACCOUNT_ID`.
2. `/sdd:init` (or `/sdd:opt-out`), then `/ci:init <pages-project>`.
3. Merge. Every pull request after that gets the same preview, comment and cleanup, and a
   push to a `preview/<slug>` branch gets a preview with no pull request: for a throwaway
   prototype, never merged. Deleting the branch removes it.

## The pin

`scripts/ci-recipes.pin` is the ci-recipes commit `/ci:init` writes and `/ci:minutes` runs.
Move it forward here, in its own pull request, after a ci-recipes change has been proved on a
repository with `/ci:update`.

## Developing

All logic is in `scripts/ci.sh`; the commands only find and call it.

```bash
bash plugins/ci/scripts/test_ci.sh
```
