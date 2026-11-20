#!/usr/bin/env bash
#
# Splices the team standards into the developer's CLAUDE.md, between the
# TEAM-STANDARDS START and END markers. Called by setup-env.sh; the PowerShell
# twin is scripts/Sync-TeamStandards.ps1, and the two must behave the same.
#
# Usage: sync-standards.sh <target CLAUDE.md> <standards file>
#
# Everything outside the marked block belongs to the developer and is kept
# byte for byte, including a leading UTF-8 BOM and a missing final newline.
# The script refuses to write (file untouched) unless the target holds exactly
# one START and one END marker line, START first. Before an update it copies
# the previous version to <target>.team-sync.bak, then rewrites the target in
# place, so a symlinked target keeps its link and the file keeps its mode.
#
# Exit codes: 0 written or already current; 1 refused or failed, nothing
# changed; 2 usage error or missing standards file.

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
BOM=$'\xEF\xBB\xBF'

if [ ! -f "$STANDARDS_FILE" ]; then
    echo "error: standards file not found: $STANDARDS_FILE" >&2
    exit 2
fi

# Command substitution drops trailing newlines; tr drops CRs from a CRLF
# checkout. A BOM is dropped too, so it never lands inside the block.
STANDARDS_CONTENT="$(tr -d '\r' < "$STANDARDS_FILE")"
STANDARDS_CONTENT="${STANDARDS_CONTENT#"$BOM"}"

# A marker inside the standards would be copied into every developer's file,
# where every later run would refuse it as damage.
case "$STANDARDS_CONTENT" in
    *"$START_MARKER"* | *"$END_MARKER"*)
        echo "error: $STANDARDS_FILE contains a team-standards marker line; it must not." >&2
        echo "       Nothing was changed. Remove the marker text from the standards file." >&2
        exit 1
        ;;
esac

MANAGED_SECTION="${START_MARKER}
${STANDARDS_CONTENT}
${END_MARKER}"

mkdir -p "$(dirname "$TARGET_FILE")"

if [ ! -f "$TARGET_FILE" ]; then
    printf '%s\n' "$MANAGED_SECTION" > "$TARGET_FILE"
    echo "Created $TARGET_FILE with team standards."
    exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Work from one snapshot, so every step sees the same lines.
SNAPSHOT="$WORK_DIR/snapshot"
cp "$TARGET_FILE" "$SNAPSHOT"

# Locate the marker lines. A line counts as a marker only when it is exactly
# the marker; a trailing CR, and a BOM at the very start of the file, are
# ignored. A marker embedded in other text is reported as damage.
#
# BINMODE=3 stops gawk on Git Bash from dropping the CR of CRLF lines, so the
# developer's own lines keep their line endings. Other awks ignore the variable.
if ! MARKER_SCAN="$(awk -v BINMODE=3 -v start="$START_MARKER" -v end="$END_MARKER" -v bom="$BOM" '
        {
            line = $0
            sub(/\r$/, "", line)
            if (NR == 1 && index(line, bom) == 1) { line = substr(line, length(bom) + 1) }
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
    ' "$SNAPSHOT")"; then
    echo "error: could not scan $TARGET_FILE for team-standards markers. Nothing was changed." >&2
    exit 1
fi
read -r START_COUNT END_COUNT START_LINE END_LINE BAD_LINES <<< "$MARKER_SCAN"

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

# Last two bytes of the snapshot, rendered so a newline reads as \n.
LAST_TWO="$(tail -c 2 "$SNAPSHOT" | od -An -c | tr -d ' \n')"

if [ "$START_COUNT" -eq 0 ] && [ "$END_COUNT" -eq 0 ]; then
    # No team block yet: append one after the developer's own content,
    # separated by exactly one blank line.
    SEPARATOR=''
    if [ -s "$SNAPSHOT" ]; then
        case "$LAST_TWO" in
            '\n\n') SEPARATOR='' ;;
            *'\n') SEPARATOR=$'\n' ;;
            *) SEPARATOR=$'\n\n' ;;
        esac
    fi
    printf '%s%s\n' "$SEPARATOR" "$MANAGED_SECTION" >> "$TARGET_FILE"
    echo "Appended team standards to $TARGET_FILE."
    exit 0
fi

if [ "$START_COUNT" -ne 1 ] || [ "$END_COUNT" -ne 1 ] || [ "$START_LINE" -ge "$END_LINE" ]; then
    fail_damaged "$TARGET_FILE has $START_COUNT START and $END_COUNT END team-standards marker(s); expected exactly one of each, START first."
fi

OLD_SECTION="$(awk -v BINMODE=3 -v sl="$START_LINE" -v el="$END_LINE" 'NR > sl && NR < el { sub(/\r$/, ""); print }' "$SNAPSHOT")"

if [ "$OLD_SECTION" = "$STANDARDS_CONTENT" ]; then
    echo "Team standards in $TARGET_FILE are already up to date."
    exit 0
fi

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

ENDS_WITH_NEWLINE=0
case "$LAST_TWO" in *'\n') ENDS_WITH_NEWLINE=1 ;; esac

UPDATED="$WORK_DIR/updated"
{
    # A BOM at the start of the file sits in front of START when START is
    # line 1; lines before START already carry it.
    if [ "$START_LINE" -eq 1 ] && [ "$(head -c 3 "$SNAPSHOT")" = "$BOM" ]; then
        printf '%s' "$BOM"
    fi
    awk -v BINMODE=3 -v sl="$START_LINE" 'NR < sl' "$SNAPSHOT"
    printf '%s\n' "$MANAGED_SECTION"
    # Hold each line back one step so the last one can be written without a
    # newline when the original had none.
    awk -v BINMODE=3 -v el="$END_LINE" -v nl="$ENDS_WITH_NEWLINE" '
        NR > el { if (held) { print prev } prev = $0; held = 1 }
        END { if (held) { printf "%s%s", prev, (nl ? "\n" : "") } }
    ' "$SNAPSHOT"
} > "$UPDATED"

# Back up, then rewrite in place: writing through the existing file keeps a
# symlink pointing where it did and keeps the file's permissions.
cp -p "$TARGET_FILE" "$TARGET_FILE.team-sync.bak"
cat "$UPDATED" > "$TARGET_FILE"
echo "Updated team standards in $TARGET_FILE (previous version saved to $TARGET_FILE.team-sync.bak)."
