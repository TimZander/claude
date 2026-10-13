#!/usr/bin/env bash
#
# Sets up (or updates) spec-driven development with OpenSpec in a repository.
#
#   bash sdd-init.sh [--repo <dir>] [--openspec-version <x.y.z>] [--no-ci] [--no-install]
#                    [--marketplace-repo <owner/repo>]
#
# Idempotent: safe to re-run, and re-running is how a repo picks up a newer
# version of the plugin's files. Two kinds of file:
#
#   Owned by the plugin, overwritten on every run (each says so at its top):
#     scripts/sdd/*                     OpenSpec runner, archive and spec checks
#     .claude/sdd-workflow.md           the flow agents follow, imported by CLAUDE.md
#     .github/workflows/sdd-checks.yml  the PR checks (skipped with --no-ci)
#     .claude/sdd-version               the plugin version installed
#
#   Owned by the repo, created only when absent, then never touched:
#     openspec/conventions.md, docs/decisions/ (README and template)
#
# And edits that only ever add: package.json (pinned OpenSpec, scripts),
# .claude/settings.json (telemetry off, the plugin enabled), .gitignore, and
# the `@.claude/sdd-workflow.md` import line in CLAUDE.md. A value the repo
# already set differently is kept and reported as a warning.
#
# Last line: `sdd-init: done` (with `, N warnings`), or `sdd-init: failed`.
# Exit status: 0 done, 1 failed, 2 usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATE="$PLUGIN_DIR/template"

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

fail() {
    echo "sdd-init: $*" >&2
    echo "sdd-init: failed"
    exit 1
}

repo="."
openspec_version="1.14.1"
ci=1
install=1
marketplace_repo="TimZander/claude"
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) [ $# -ge 2 ] || usage; repo="$2"; shift 2 ;;
        --openspec-version) [ $# -ge 2 ] || usage; openspec_version="$2"; shift 2 ;;
        --marketplace-repo) [ $# -ge 2 ] || usage; marketplace_repo="$2"; shift 2 ;;
        --no-ci) ci=0; shift ;;
        --no-install) install=0; shift ;;
        -h|--help) usage ;;
        *) echo "sdd-init: unknown argument: $1" >&2; usage ;;
    esac
done
printf '%s' "$openspec_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || { echo "sdd-init: --openspec-version must be an exact x.y.z version" >&2; exit 2; }

command -v git >/dev/null || fail "git is required"
command -v node >/dev/null || fail "node (>= 20.19) is required: OpenSpec runs on it"
root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || fail "$repo is not inside a git repository"
cd "$root"

version="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version || "0.0.0")' \
    "$PLUGIN_DIR/.claude-plugin/plugin.json")"
echo "Setting up sdd $version in $root"

warnings=0
note() {
    case "$1" in
        warning:*) warnings=$((warnings + 1)); echo "  $1" ;;
        *) echo "  $1" ;;
    esac
}

# Copies a plugin-owned file, reporting added/updated/unchanged.
owned() {
    local rel="$1" mode="${2:-}"
    local src="$TEMPLATE/$rel"
    [ -f "$src" ] || fail "plugin file missing: $src (reinstall the plugin)"
    mkdir -p "$(dirname "$rel")"
    if [ ! -f "$rel" ]; then
        cp "$src" "$rel"; note "added $rel"
    elif ! cmp -s "$src" "$rel"; then
        cp "$src" "$rel"; note "updated $rel"
    fi
    [ -z "$mode" ] || chmod "$mode" "$rel"
}

# Copies a repo-owned starter file only when absent.
seed() {
    local rel="$1"
    [ -e "$rel" ] && return 0
    mkdir -p "$(dirname "$rel")"
    cp "$TEMPLATE/$rel" "$rel"
    note "added $rel"
}

echo "Plugin files:"
for f in openspec.sh sdd-archive.sh check-specs.sh; do
    owned "scripts/sdd/$f" 755
done
owned scripts/sdd/setup-agent-skills.mjs
owned .claude/sdd-workflow.md
if [ $ci -eq 1 ]; then
    owned .github/workflows/sdd-checks.yml
fi
if [ "$(cat .claude/sdd-version 2>/dev/null || true)" != "$version" ]; then
    printf '%s\n' "$version" > .claude/sdd-version
    note "set .claude/sdd-version to $version"
fi

echo "Repo files:"
seed openspec/conventions.md
if [ ! -d docs/decisions ]; then
    seed docs/decisions/README.md
    seed docs/decisions/template.md
fi

echo "Settings:"
while IFS= read -r line; do note "$line"; done < <(node "$SCRIPT_DIR/sdd-init-json.mjs" package package.json "$openspec_version" || echo "warning: package.json not updated")
while IFS= read -r line; do note "$line"; done < <(node "$SCRIPT_DIR/sdd-init-json.mjs" settings .claude/settings.json "$marketplace_repo" || echo "warning: .claude/settings.json not updated")

touch .gitignore
for line in 'node_modules' '.claude/skills/openspec-*/' '.claude/commands/opsx/'; do
    if ! grep -qxF -- "$line" .gitignore; then
        [ -z "$(tail -c 1 .gitignore)" ] || echo >> .gitignore
        echo "$line" >> .gitignore
        note "added $line to .gitignore"
    fi
done

import='@.claude/sdd-workflow.md'
if [ ! -f CLAUDE.md ]; then
    cat > CLAUDE.md <<EOF
# CLAUDE.md

Guidance for agents working in this repository.

## Spec-driven workflow

$import

## Project

<!-- Stack, commands, and rules specific to this repository. -->
EOF
    note "added CLAUDE.md"
elif ! grep -qxF -- "$import" CLAUDE.md; then
    { echo; echo "## Spec-driven workflow"; echo; echo "$import"; } >> CLAUDE.md
    note "added the $import import to CLAUDE.md"
    if grep -qiE 'openspec|/opsx:' CLAUDE.md; then
        note "warning: CLAUDE.md already describes an OpenSpec workflow; remove what .claude/sdd-workflow.md now covers"
    fi
fi

if [ $install -eq 1 ]; then
    command -v npm >/dev/null || fail "npm is required (or pass --no-install)"
    echo "Installing the pinned OpenSpec CLI:"
    OPENSPEC_TELEMETRY=0 npm install --no-audit --no-fund >/dev/null || fail "npm install failed"
    note "npm install done"
fi

if [ $ci -eq 1 ] && [ ! -f package-lock.json ]; then
    note "warning: no package-lock.json: the sdd-checks workflow runs \`npm ci\`, which needs one; run \`npm install\` and commit it"
fi

if [ $warnings -gt 0 ]; then
    echo "sdd-init: done, $warnings warnings"
else
    echo "sdd-init: done"
fi
