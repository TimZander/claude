#!/usr/bin/env bash
#
# Bootstraps the developer's local environment:
#   1. Installs global git hooks via core.hooksPath
#   2. Syncs team standards into ~/.claude/CLAUDE.md
#   3. Merges team settings into ~/.claude/settings.json
#   4. Sets the Azure DevOps CLI default organization, when none is set
#
# Safe to re-run — updates in place without duplication.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
# Keep in step with $TeamAdoOrg in setup-env.ps1.
TEAM_ADO_ORG="https://dev.azure.com/bgvone"

###############################################################################
# 1. Global git hooks
###############################################################################

HOOKS_DIR="$HOME/.git-hooks"
HOOKS_MANIFEST="$REPO_ROOT/hooks/hooks.json"

echo "=== Git Hooks ==="

if [ ! -f "$HOOKS_MANIFEST" ]; then
    echo "Warning: Hooks manifest not found: $HOOKS_MANIFEST" >&2
else
    mkdir -p "$HOOKS_DIR"

    # Parse enabled hooks from manifest (name:source pairs, one per line)
    if command -v jq &>/dev/null; then
        hook_entries=$(jq -r '.hooks[] | select(.enabled != false) | .name + ":" + .source' "$HOOKS_MANIFEST")
    elif command -v node &>/dev/null; then
        hook_entries=$(node -e "
            const m = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
            m.hooks.filter(h => h.enabled !== false).forEach(h => console.log(h.name + ':' + h.source));
        " "$HOOKS_MANIFEST")
    elif command -v python3 &>/dev/null; then
        hook_entries=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    for h in json.load(f)['hooks']:
        if h.get('enabled', True):
            print(h['name'] + ':' + h['source'])
" "$HOOKS_MANIFEST")
    elif command -v python &>/dev/null; then
        hook_entries=$(python -c "
import json, sys
with open(sys.argv[1]) as f:
    for h in json.load(f)['hooks']:
        if h.get('enabled', True):
            print(h['name'] + ':' + h['source'])
" "$HOOKS_MANIFEST")
    else
        echo "Error: jq, node, python3, or python is required to parse hooks manifest." >&2
        exit 1
    fi

    # Install each enabled hook
    while IFS=':' read -r hook_name hook_source; do
        [ -z "$hook_name" ] && continue
        source_path="$REPO_ROOT/hooks/$hook_source"
        target_path="$HOOKS_DIR/$hook_name"

        if [ ! -f "$source_path" ]; then
            echo "Warning: Hook source not found: $source_path" >&2
            continue
        fi

        if [ -f "$target_path" ] && diff -q "$source_path" "$target_path" &>/dev/null; then
            echo "Hook '$hook_name' is already up to date."
        else
            action="Installed"
            [ -f "$target_path" ] && action="Updated"
            cp "$source_path" "$target_path"
            chmod +x "$target_path"
            echo "$action hook '$hook_name'."
        fi
    done <<< "$hook_entries"

    # Set core.hooksPath globally
    current_hooks_path="$(git config --global core.hooksPath 2>/dev/null || true)"
    if [ "$current_hooks_path" = "$HOOKS_DIR" ]; then
        echo "Global core.hooksPath already set to $HOOKS_DIR"
    else
        git config --global core.hooksPath "$HOOKS_DIR"
        echo "Set global core.hooksPath to $HOOKS_DIR"
    fi
fi

echo ""

###############################################################################
# 2. Team standards sync
###############################################################################

echo "=== Team Standards ==="

STANDARDS_FILE="$REPO_ROOT/standards/CLAUDE.md"
CLAUDE_DIR="$HOME/.claude"
TARGET_FILE="$CLAUDE_DIR/CLAUDE.md"
STANDARDS_FAILED=0
mkdir -p "$CLAUDE_DIR"

if [ ! -f "$STANDARDS_FILE" ]; then
    echo "Warning: Standards file not found: $STANDARDS_FILE" >&2
else
    # The splice lives in its own script so it can be tested in isolation
    # (scripts/test_sync-standards.sh). When it refuses (damaged markers), the
    # settings sync below is independent, so carry on and fail at the end.
    if ! bash "$REPO_ROOT/scripts/sync-standards.sh" "$TARGET_FILE" "$STANDARDS_FILE"; then
        STANDARDS_FAILED=1
        echo "Team standards were not synced; continuing with the remaining steps." >&2
    fi
fi

echo ""

###############################################################################
# 3. Team settings sync
###############################################################################

echo "=== Team Settings ==="

SETTINGS_SOURCE="$REPO_ROOT/standards/settings.json"
SETTINGS_TARGET="$CLAUDE_DIR/settings.json"

if [ ! -f "$SETTINGS_SOURCE" ]; then
    echo "No standards/settings.json found — skipping settings sync."
elif [ ! -f "$SETTINGS_TARGET" ]; then
    cp "$SETTINGS_SOURCE" "$SETTINGS_TARGET"
    echo "Created $SETTINGS_TARGET with team settings."
else
    # Deep-merge via a Python helper (team = base, user overrides win on scalar
    # conflicts, arrays are unioned). Python replaces jq here: jq is often absent
    # on Windows/Git-Bash, where it used to silently skip the whole settings sync.
    PYTHON_BIN=""
    for _candidate in python3 python; do
        if command -v "$_candidate" >/dev/null 2>&1; then
            PYTHON_BIN="$_candidate"
            break
        fi
    done

    if [ -z "$PYTHON_BIN" ]; then
        echo "Error: neither python3 nor python found — cannot merge settings.json." >&2
        echo "       Install Python (or merge $SETTINGS_TARGET manually) and re-run." >&2
    elif ! MERGED="$("$PYTHON_BIN" "$REPO_ROOT/scripts/merge_settings.py" "$SETTINGS_SOURCE" "$SETTINGS_TARGET")" || [ -z "$MERGED" ]; then
        echo "Error: settings merge failed — leaving $SETTINGS_TARGET unchanged." >&2
    else
        EXISTING_SETTINGS="$(cat "$SETTINGS_TARGET")"
        if [ "$MERGED" = "$EXISTING_SETTINGS" ]; then
            echo "Settings in $SETTINGS_TARGET are already up to date."
        else
            printf '%s\n' "$MERGED" > "$SETTINGS_TARGET"
            echo "Merged team settings into $SETTINGS_TARGET."
        fi
    fi
fi

echo ""

###############################################################################
# 4. Azure DevOps CLI default organization
###############################################################################

echo "=== Azure DevOps CLI ==="

# Never fails setup: missing tools and az errors are reported and skipped.
bash "$REPO_ROOT/scripts/set-az-default-org.sh" "$TEAM_ADO_ORG" || true

echo ""
if [ "$STANDARDS_FAILED" -ne 0 ]; then
    echo "=== Setup finished with errors: team standards were not synced (see above) ===" >&2
    exit 1
fi
echo "=== Setup complete ==="
