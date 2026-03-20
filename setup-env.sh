#!/usr/bin/env bash
#
# Bootstraps the developer's local environment:
#   1. Installs global git hooks via core.hooksPath
#   2. Syncs team standards into ~/.claude/CLAUDE.md
#
# Safe to re-run — updates in place without duplication.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

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

START_MARKER='<!-- TEAM-STANDARDS:tzander-skills:START -->'
END_MARKER='<!-- TEAM-STANDARDS:tzander-skills:END -->'

STANDARDS_FILE="$REPO_ROOT/standards/CLAUDE.md"
CLAUDE_DIR="$HOME/.claude"
TARGET_FILE="$CLAUDE_DIR/CLAUDE.md"

if [ ! -f "$STANDARDS_FILE" ]; then
    echo "Warning: Standards file not found: $STANDARDS_FILE" >&2
else
    STANDARDS_CONTENT="$(cat "$STANDARDS_FILE")"
    MANAGED_SECTION="${START_MARKER}
${STANDARDS_CONTENT}
${END_MARKER}"

    mkdir -p "$CLAUDE_DIR"

    if [ ! -f "$TARGET_FILE" ]; then
        printf '%s' "$MANAGED_SECTION" > "$TARGET_FILE"
        echo "Created $TARGET_FILE with team standards."
    elif grep -qF "$START_MARKER" "$TARGET_FILE"; then
        EXISTING_CONTENT="$(cat "$TARGET_FILE")"

        OLD_SECTION_FILE="$(mktemp)"
        awk -v start="$START_MARKER" -v end="$END_MARKER" '
            $0 == start { capture=1; next }
            $0 == end { capture=0; next }
            capture { print }
        ' "$TARGET_FILE" > "$OLD_SECTION_FILE"

        SECTION_FILE="$(mktemp)"
        printf '%s\n' "$MANAGED_SECTION" > "$SECTION_FILE"
        UPDATED_CONTENT="$(awk -v start="$START_MARKER" -v end="$END_MARKER" -v sfile="$SECTION_FILE" '
            $0 == start { printing=0; while ((getline line < sfile) > 0) print line; close(sfile); next }
            $0 == end { printing=1; next }
            printing!=0 { print }
        ' "$TARGET_FILE")"
        rm -f "$SECTION_FILE"

        if [ "$UPDATED_CONTENT" = "$EXISTING_CONTENT" ]; then
            echo "Team standards in $TARGET_FILE are already up to date."
        else
            NEW_SECTION_FILE="$(mktemp)"
            printf '%s\n' "$STANDARDS_CONTENT" > "$NEW_SECTION_FILE"
            echo "Changes:"
            diff "$OLD_SECTION_FILE" "$NEW_SECTION_FILE" \
                --old-line-format='  - %L' \
                --new-line-format='  + %L' \
                --unchanged-line-format='' || true
            rm -f "$NEW_SECTION_FILE"

            printf '%s' "$UPDATED_CONTENT" > "$TARGET_FILE"
            echo "Updated team standards in $TARGET_FILE."
        fi
        rm -f "$OLD_SECTION_FILE"
    else
        if [ -s "$TARGET_FILE" ]; then
            TAIL_CHAR="$(tail -c 1 "$TARGET_FILE")"
            if [ "$TAIL_CHAR" != "" ]; then
                printf '\n\n' >> "$TARGET_FILE"
            else
                printf '\n' >> "$TARGET_FILE"
            fi
        fi
        printf '%s' "$MANAGED_SECTION" >> "$TARGET_FILE"
        echo "Appended team standards to $TARGET_FILE."
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
else
    if ! command -v jq &>/dev/null; then
        echo "Warning: jq is not installed — skipping settings.json sync." >&2
    else
        if [ ! -f "$SETTINGS_TARGET" ]; then
            cp "$SETTINGS_SOURCE" "$SETTINGS_TARGET"
            echo "Created $SETTINGS_TARGET with team settings."
        else
            # Deep-merge: team settings are the base, user settings win on
            # scalar conflicts, arrays are unioned (deduplicated).
            MERGED="$(jq -s '
                def deep_merge:
                    .[0] as $a | .[1] as $b |
                    if ($a | type) == "object" and ($b | type) == "object" then
                        ([($a | keys[]), ($b | keys[])] | unique) as $keys |
                        reduce ($keys | .[]) as $k ({};
                            if ($a | has($k)) and ($b | has($k))
                            then . + { ($k): ([$a[$k], $b[$k]] | deep_merge) }
                            elif ($b | has($k)) then . + { ($k): $b[$k] }
                            else . + { ($k): $a[$k] }
                            end)
                    elif ($a | type) == "array" and ($b | type) == "array" then
                        ($a + $b) | unique
                    else $b
                    end;
                deep_merge
            ' "$SETTINGS_SOURCE" "$SETTINGS_TARGET")"

            EXISTING_SETTINGS="$(cat "$SETTINGS_TARGET")"
            if [ "$MERGED" = "$EXISTING_SETTINGS" ]; then
                echo "Settings in $SETTINGS_TARGET are already up to date."
            else
                printf '%s\n' "$MERGED" > "$SETTINGS_TARGET"
                echo "Merged team settings into $SETTINGS_TARGET."
            fi
        fi
    fi
fi

echo ""
echo "=== Setup complete ==="
