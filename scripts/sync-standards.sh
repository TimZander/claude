#!/usr/bin/env bash
#
# Splices the team standards into the developer's CLAUDE.md, between the
# TEAM-STANDARDS START and END markers. Called by setup-env.sh.
#
# Usage: sync-standards.sh <target CLAUDE.md> <standards file>
#
# Everything outside the marked block belongs to the developer and is kept
# byte for byte. The script refuses to write (exit 1, file untouched) unless
# the target holds exactly one START and one END marker line, START first.
# Before replacing an existing file it saves the previous version to
# <target>.team-sync.bak, then swaps in the new content with a single rename.
#
# Exit codes: 0 success or already current, 1 damaged markers, 2 usage error.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: sync-standards.sh <target CLAUDE.md> <standards file>" >&2
    exit 2
fi

TARGET_FILE="$1"
STANDARDS_FILE="$2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

START_MARKER='<!-- TEAM-STANDARDS:tzander-skills:START -->'
END_MARKER='<!-- TEAM-STANDARDS:tzander-skills:END -->'

if [ ! -f "$STANDARDS_FILE" ]; then
    echo "error: standards file not found: $STANDARDS_FILE" >&2
    exit 2
fi

# Command substitution drops trailing newlines; tr drops CRs from a CRLF checkout.
STANDARDS_CONTENT="$(tr -d '\r' < "$STANDARDS_FILE")"
MANAGED_SECTION="${START_MARKER}
${STANDARDS_CONTENT}
${END_MARKER}"

mkdir -p "$(dirname "$TARGET_FILE")"

if [ ! -f "$TARGET_FILE" ]; then
    printf '%s\n' "$MANAGED_SECTION" > "$TARGET_FILE"
    echo "Created $TARGET_FILE with team standards."
    exit 0
fi

# Locate the marker lines. A line counts as a marker only when it is exactly
# the marker (a trailing CR is ignored); a marker embedded in other text is
# reported as damage rather than silently skipped.
#
# BINMODE=3 stops gawk on Git Bash from dropping the CR of CRLF lines, so the
# developer's own lines keep their line endings. Other awks ignore the variable.
read -r START_COUNT END_COUNT START_LINE END_LINE BAD_LINES < <(
    awk -v BINMODE=3 -v start="$START_MARKER" -v end="$END_MARKER" '
        {
            line = $0
            sub(/\r$/, "", line)
            if (index(line, start)) {
                if (line == start) { ns++; sl = NR } else { bad = bad NR "," }
            }
            if (index(line, end)) {
                if (line == end) { ne++; el = NR } else { bad = bad NR "," }
            }
        }
        END {
            if (bad == "") { bad = "-" } else { sub(/,$/, "", bad) }
            print ns + 0, ne + 0, sl + 0, el + 0, bad
        }
    ' "$TARGET_FILE"
)

fail_damaged() {
    echo "error: $1" >&2
    echo "       Nothing was changed. Fix the markers in $TARGET_FILE by hand, or delete" >&2
    echo "       the whole team-standards block (markers included) to have it re-appended," >&2
    echo "       then re-run setup." >&2
    exit 1
}

if [ "$BAD_LINES" != "-" ]; then
    fail_damaged "a team-standards marker in $TARGET_FILE is not on a line of its own (line $BAD_LINES)."
fi

if [ "$START_COUNT" -eq 0 ] && [ "$END_COUNT" -eq 0 ]; then
    # No team block yet: append one after the developer's own content.
    if [ -s "$TARGET_FILE" ]; then
        if [ -n "$(tail -c 1 "$TARGET_FILE")" ]; then
            printf '\n\n' >> "$TARGET_FILE"
        else
            printf '\n' >> "$TARGET_FILE"
        fi
    fi
    printf '%s\n' "$MANAGED_SECTION" >> "$TARGET_FILE"
    echo "Appended team standards to $TARGET_FILE."
    exit 0
fi

if [ "$START_COUNT" -ne 1 ] || [ "$END_COUNT" -ne 1 ] || [ "$START_LINE" -ge "$END_LINE" ]; then
    fail_damaged "$TARGET_FILE has $START_COUNT START and $END_COUNT END team-standards marker(s); expected exactly one of each, START first."
fi

OLD_SECTION="$(awk -v BINMODE=3 -v sl="$START_LINE" -v el="$END_LINE" 'NR > sl && NR < el { sub(/\r$/, ""); print }' "$TARGET_FILE")"

if [ "$OLD_SECTION" = "$STANDARDS_CONTENT" ]; then
    echo "Team standards in $TARGET_FILE are already up to date."
    exit 0
fi

WORK_DIR="$(mktemp -d)"
STAGED_FILE=""
trap 'rm -rf "$WORK_DIR"; [ -n "$STAGED_FILE" ] && rm -f "$STAGED_FILE"' EXIT

printf '%s\n' "$OLD_SECTION" > "$WORK_DIR/old"
printf '%s\n' "$STANDARDS_CONTENT" > "$WORK_DIR/new"
echo "Changes:"
if diff --old-line-format='' --new-line-format='' --unchanged-line-format='' /dev/null /dev/null >/dev/null 2>&1; then
    diff "$WORK_DIR/old" "$WORK_DIR/new" \
        --old-line-format='  - %L' \
        --new-line-format='  + %L' \
        --unchanged-line-format='' || true
else
    # BSD diff (macOS) lacks --*-line-format; post-process a unified diff instead.
    { diff -u "$WORK_DIR/old" "$WORK_DIR/new" || true; } \
        | awk -f "$SCRIPT_DIR/diff-preview.awk"
fi

# Build the replacement next to the target so the final mv is a same-filesystem
# rename. Copying the target first keeps its permissions on the new file.
STAGED_FILE="$(mktemp "$(dirname "$TARGET_FILE")/.claude-md-sync.XXXXXX")"
cp -p "$TARGET_FILE" "$STAGED_FILE"
{
    awk -v BINMODE=3 -v sl="$START_LINE" 'NR < sl' "$TARGET_FILE"
    printf '%s\n' "$MANAGED_SECTION"
    awk -v BINMODE=3 -v el="$END_LINE" 'NR > el' "$TARGET_FILE"
} > "$STAGED_FILE"

cp -p "$TARGET_FILE" "$TARGET_FILE.team-sync.bak"
mv -f "$STAGED_FILE" "$TARGET_FILE"
STAGED_FILE=""
echo "Updated team standards in $TARGET_FILE (previous version saved to $TARGET_FILE.team-sync.bak)."
