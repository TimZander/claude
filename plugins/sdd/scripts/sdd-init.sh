#!/usr/bin/env bash
#
# Sets up (or updates) spec-driven development with OpenSpec in a repository.
#
#   bash sdd-init.sh [--repo <dir>] [--openspec-version <x.y.z>] [--no-ci] [--no-install]
#                    [--host github|azure-devops] [--marketplace-repo <owner/repo>]
#
# The host decides which CI template is installed. Without --host it is package.json's
# `sdd.host`, else azure-devops when the `origin` remote is an Azure Repos URL (read by the same
# parser /sdd:archive-pr uses, sdd-azure.mjs remote), else github. An Azure DevOps host, and any
# host given with --host, is recorded as `"sdd": { "host": ... }` in package.json, so later
# runs and /sdd:archive-pr agree on it. A --host that contradicts package.json fails: change
# the setting first.
#
# Idempotent: safe to re-run, and re-running is how a repo picks up a newer
# version of the plugin's files. Two kinds of file:
#
#   Owned by the plugin, overwritten on every run (each says so at its top):
#     scripts/sdd/*                     OpenSpec runner, archive and spec checks, base pins,
#                                       settings, the GitHub CI reporter, the Azure DevOps
#                                       archive-PR helpers, and the SessionStart hook
#                                       (npm ci --ignore-scripts when stale, sdd status)
#     .claude/sdd-workflow.md           the flow agents follow, imported by CLAUDE.md
#     .github/workflows/sdd-checks.yml  the PR checks on GitHub (skipped with --no-ci)
#     .azure-pipelines/sdd-checks.yml   the PR checks on Azure DevOps (skipped with --no-ci)
#     .claude/sdd-version               the plugin version installed
#
#   Owned by the repo, created only when absent, then never touched:
#     openspec/conventions.md, docs/decisions/ (README and template)
#
# And edits that only ever add: package.json (pinned OpenSpec, scripts, and sdd.host on Azure
# DevOps or when --host is given),
# .claude/settings.json (telemetry off, the plugin enabled, the SessionStart hook),
# .gitignore, and
# the `@.claude/sdd-workflow.md` import line in CLAUDE.md. A value the repo
# already set differently is kept and reported as a warning. The one removal: the
# opt-out line /sdd:opt-out writes (scripts/optout-line.txt, matched exactly) is
# deleted from CLAUDE.md, since running this is the owner's decision to use sdd.
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
host=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) [ $# -ge 2 ] || usage; repo="$2"; shift 2 ;;
        --openspec-version) [ $# -ge 2 ] || usage; openspec_version="$2"; shift 2 ;;
        --marketplace-repo) [ $# -ge 2 ] || usage; marketplace_repo="$2"; shift 2 ;;
        --host) [ $# -ge 2 ] || usage; host="$2"; shift 2 ;;
        --no-ci) ci=0; shift ;;
        --no-install) install=0; shift ;;
        -h|--help) usage ;;
        *) echo "sdd-init: unknown argument: $1" >&2; usage ;;
    esac
done
printf '%s' "$openspec_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || { echo "sdd-init: --openspec-version must be an exact x.y.z version" >&2; exit 2; }
case "$host" in
    ""|github|azure-devops) ;;
    *) echo "sdd-init: --host must be github or azure-devops" >&2; exit 2 ;;
esac

TMPDIR_INIT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_INIT"' EXIT

command -v git >/dev/null || fail "git is required"
command -v node >/dev/null || fail "node (>= 20.19) is required: OpenSpec runs on it"
root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || fail "$repo is not inside a git repository"
cd "$root"

version="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version || "0.0.0")' \
    "$PLUGIN_DIR/.claude-plugin/plugin.json")"
# The host: --host, else package.json's sdd.host, else the origin remote, else github.
pkg_host="$(node -e '
    try {
        const p = JSON.parse(require("fs").readFileSync("package.json", "utf8"))
        const h = p && p.sdd && p.sdd.host
        if (typeof h === "string") {
            process.stdout.write(h)
        }
    } catch {}' 2>/dev/null || true)"
if [ -n "$host" ]; then
    host_from="--host"
    if [ -n "$pkg_host" ] && [ "$pkg_host" != "$host" ]; then
        fail "--host $host contradicts package.json's sdd.host ($pkg_host): change the setting first"
    fi
elif [ -n "$pkg_host" ]; then
    host="$pkg_host"; host_from="package.json"
elif node "$TEMPLATE/scripts/sdd/sdd-azure.mjs" remote >/dev/null 2>&1; then
    host=azure-devops; host_from="the origin remote"
else
    host=github; host_from="the default"
fi
case "$host" in
    github|azure-devops) ;;
    *) fail "package.json's sdd.host is $host, not github or azure-devops" ;;
esac

# A repository sdd set up before records no host, and was set up for GitHub. Detection moving it
# to Azure DevOps is a change of host: refuse it where GitHub-only settings would then fail
# every sdd script, and say so loudly otherwise.
switched=0
if [ "$host_from" = "the origin remote" ] && [ -f .claude/sdd-version ]; then
    switched=1
    github_only="$(node -e '
        try {
            const sdd = JSON.parse(require("fs").readFileSync("package.json", "utf8")).sdd || {}
            const set = []
            if (sdd.statuses === true) {
                set.push("statuses")
            }
            if (Array.isArray(sdd.archiveVerdicts) && sdd.archiveVerdicts.length > 0) {
                set.push("archiveVerdicts")
            }
            if ("specDiffComment" in sdd) {
                set.push("specDiffComment")
            }
            process.stdout.write(set.join(", "))
        } catch {}' 2>/dev/null || true)"
    if [ -n "$github_only" ]; then
        fail "this repository was set up for GitHub, and its origin is now Azure Repos, but package.json sets GitHub-only sdd settings ($github_only). Remove them to move it to Azure DevOps, or pass --host github to keep it on GitHub"
    fi
fi

echo "Setting up sdd $version in $root (host: $host, from $host_from)"

warnings=0
note() {
    case "$1" in
        warning:*) warnings=$((warnings + 1)); echo "  $1" ;;
        *) echo "  $1" ;;
    esac
}

if [ $switched -eq 1 ]; then
    note "warning: this repository was set up for GitHub, and its origin is Azure Repos: moving it to Azure DevOps. Re-run with --host github to keep it on GitHub"
fi
# An Azure DevOps Server (on-premises) remote isn't one sdd can read: it stays on GitHub.
if [ "$host" = github ] && [ "$host_from" = "the default" ]; then
    case "$(git remote get-url origin 2>/dev/null || true)" in
        */_git/*|*/_optimized/*) note "warning: origin looks like Azure DevOps Server, which sdd doesn't support, so this is set up for GitHub; pass --host to choose" ;;
    esac
fi

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
for f in openspec.sh sdd-archive.sh check-specs.sh session-start.sh sdd-azure-pr.sh; do
    owned "scripts/sdd/$f" 755
done
for f in setup-agent-skills.mjs sdd-config.mjs sdd-specs.mjs sdd-github.mjs sdd-azure.mjs; do
    owned "scripts/sdd/$f"
done
owned .claude/sdd-workflow.md
if [ $ci -eq 1 ]; then
    if [ "$host" = azure-devops ]; then
        owned .azure-pipelines/sdd-checks.yml
    else
        owned .github/workflows/sdd-checks.yml
    fi
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
while IFS= read -r line; do note "$line"; done < <(node "$SCRIPT_DIR/sdd-init-json.mjs" package package.json "$openspec_version" "$host" "$([ "$host_from" = --host ] && echo explicit || echo detected)" || echo "warning: package.json not updated")
while IFS= read -r line; do note "$line"; done < <(node "$SCRIPT_DIR/sdd-init-json.mjs" settings .claude/settings.json "$marketplace_repo" || echo "warning: .claude/settings.json not updated")

touch .gitignore
for line in 'node_modules' '.claude/skills/openspec-*/' '.claude/commands/opsx/'; do
    if ! grep -qxF -- "$line" .gitignore; then
        [ -z "$(tail -c 1 .gitignore)" ] || echo >> .gitignore
        echo "$line" >> .gitignore
        note "added $line to .gitignore"
    fi
done

# An earlier opt-out would contradict the workflow import. One pass drops the exact line (not
# inside a fenced code block), the blank line it leaves behind, and blank lines it leaves at
# the end, CRLF or not, then writes the result back into the same file, so a symlinked
# CLAUDE.md stays a symlink. A CLAUDE.md that was only
# the opt-out (as /sdd:opt-out creates it) is removed, so the template below replaces it.
if [ -f CLAUDE.md ]; then
    optout_tmp="$TMPDIR_INIT/claude-md"
    removed="$(awk -v line="$(tr -d '\r' < "$SCRIPT_DIR/optout-line.txt")" -v out="$optout_tmp" '
        { l[NR] = $0; t = $0; sub(/\r$/, "", t); sub(/[ \t]+$/, "", t); b[NR] = (t == ""); m[NR] = 0 }
        # Fences as in Markdown: indented at most 3 spaces, no backtick in the info string of a
        # backtick fence, closed only by the same character, at least as long, nothing after it.
        t ~ /^(   |  | )?(```|~~~)/ {
            s = t; sub(/^ */, "", s); c = substr(s, 1, 1); n = 0
            while (substr(s, n + 1, 1) == c) n++
            rest = substr(s, n + 1)
            if (!fence && !(c == "`" && index(rest, "`"))) { fence = 1; fc = c; fl = n; next }
            if (fence && c == fc && n >= fl && rest ~ /^[ \t]*$/) { fence = 0; next }
        }
        !fence { m[NR] = (t == line) }
        END {
            k = 0; removed = 0; skip = 0
            for (i = 1; i <= NR; i++) {
                if (m[i]) { removed++; skip = (k == 0 || ob[k]); continue }
                if (skip && b[i]) { skip = 0; continue }
                skip = 0; o[++k] = l[i]; ob[k] = b[i]
            }
            if (removed) while (k > 0 && ob[k]) k--
            printf "" > out
            for (i = 1; i <= k; i++) print o[i] > out
            print removed
        }' CLAUDE.md)"
    if [ "$removed" != 0 ]; then
        if [ ! -L CLAUDE.md ] && ! awk '{ sub(/\r$/, "") } $0 != "" && $0 != "# CLAUDE.md" { f = 1 } END { exit !f }' "$optout_tmp"; then
            rm -f CLAUDE.md
        else
            cat "$optout_tmp" > CLAUDE.md
        fi
        note "removed the sdd opt-out from CLAUDE.md"
    fi
fi

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

if ! node scripts/sdd/sdd-config.mjs --root . --json >/dev/null 2>"$TMPDIR_INIT/config.err"; then
    note "warning: $(sed 's/^sdd-config: //' "$TMPDIR_INIT/config.err" | head -n 1); the sdd scripts fail until it is fixed"
elif [ "$(node scripts/sdd/sdd-config.mjs --root . pins)" = true ] && [ -d openspec/changes ]; then
    for d in openspec/changes/*/; do
        [ -d "$d" ] || continue
        d="${d%/}"; d="${d##*/}"
        [ "$d" = archive ] && continue
        if [ ! -f "openspec/changes/$d/base-pins.json" ]; then
            note "warning: active change $d has no base-pins.json, so check-specs fails until it has one: check its deltas still hold against the main specs, then run \`npm run spec:pin -- $d\`"
        fi
    done
fi

if [ $ci -eq 1 ] && [ ! -f package-lock.json ]; then
    note "warning: no package-lock.json: sdd-checks CI runs \`npm ci\`, which needs one; run \`npm install\` and commit it"
fi

# The other host's checks, from an earlier run or a move: they no longer run, or never could.
if [ "$host" = azure-devops ] && [ -f .github/workflows/sdd-checks.yml ]; then
    note "warning: .github/workflows/sdd-checks.yml is for GitHub, and this repository is on Azure DevOps: delete it"
elif [ "$host" = github ] && [ -f .azure-pipelines/sdd-checks.yml ]; then
    note "warning: .azure-pipelines/sdd-checks.yml is for Azure DevOps, and this repository is on GitHub: delete it"
fi

if [ $warnings -gt 0 ]; then
    echo "sdd-init: done, $warnings warnings"
else
    echo "sdd-init: done"
fi
