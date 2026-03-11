#!/usr/bin/env bash
#
# Syncs team standards into ~/.claude/.
#
# 1. CLAUDE.md — upserts a managed section (between markers) into
#    ~/.claude/CLAUDE.md, preserving personal content outside the markers.
# 2. settings.json — deep-merges standards/settings.json into
#    ~/.claude/settings.json (arrays are unioned, objects are merged;
#    personal entries are never removed).

set -euo pipefail

START_MARKER='<!-- TEAM-STANDARDS:tzander-skills:START -->'
END_MARKER='<!-- TEAM-STANDARDS:tzander-skills:END -->'

# Resolve paths
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
STANDARDS_FILE="$REPO_ROOT/standards/CLAUDE.md"
CLAUDE_DIR="$HOME/.claude"
TARGET_FILE="$CLAUDE_DIR/CLAUDE.md"

# Read the canonical standards
if [ ! -f "$STANDARDS_FILE" ]; then
    echo "Error: Standards file not found: $STANDARDS_FILE" >&2
    exit 1
fi
STANDARDS_CONTENT="$(cat "$STANDARDS_FILE")"

# Build the managed section
MANAGED_SECTION="${START_MARKER}
${STANDARDS_CONTENT}
${END_MARKER}"

# Ensure ~/.claude directory exists
mkdir -p "$CLAUDE_DIR"

if [ ! -f "$TARGET_FILE" ]; then
    # No existing file — create it with just the managed section
    printf '%s' "$MANAGED_SECTION" > "$TARGET_FILE"
    echo "Created $TARGET_FILE with team standards."
elif grep -qF "$START_MARKER" "$TARGET_FILE"; then
    # Markers exist — replace the managed section in-place
    EXISTING_CONTENT="$(cat "$TARGET_FILE")"

    # Use awk to replace everything between (and including) the markers.
    # Write the managed section to a temp file because awk -v cannot handle
    # multi-line strings (causes "newline in string" errors).
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
        printf '%s' "$UPDATED_CONTENT" > "$TARGET_FILE"
        echo "Updated team standards in $TARGET_FILE."
    fi
else
    # No markers — append the managed section
    # Add appropriate spacing
    if [ -s "$TARGET_FILE" ]; then
        TAIL_CHAR="$(tail -c 1 "$TARGET_FILE")"
        if [ "$TAIL_CHAR" != "" ]; then
            # File doesn't end with newline
            printf '\n\n' >> "$TARGET_FILE"
        else
            printf '\n' >> "$TARGET_FILE"
        fi
    fi
    printf '%s' "$MANAGED_SECTION" >> "$TARGET_FILE"
    echo "Appended team standards to $TARGET_FILE."
fi

# ── settings.json sync ──────────────────────────────────────────────────────

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
