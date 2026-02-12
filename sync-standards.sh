#!/usr/bin/env bash
#
# Syncs team coding standards into ~/.claude/CLAUDE.md.
#
# Reads standards/CLAUDE.md from this repository and upserts a managed section
# into the user's ~/.claude/CLAUDE.md, preserving any personal content outside
# the markers.

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

    # Use awk to replace everything between (and including) the markers
    UPDATED_CONTENT="$(awk -v start="$START_MARKER" -v end="$END_MARKER" -v section="$MANAGED_SECTION" '
        $0 == start { printing=0; print section; next }
        $0 == end { printing=1; next }
        printing!=0 { print }
    ' "$TARGET_FILE")"

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
