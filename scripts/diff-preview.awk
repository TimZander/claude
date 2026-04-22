# Reformat `diff -u` output into the "Changes:" preview style used by
# setup-env.sh when reporting what team-standards changes were applied.
#
# Input: standard unified-diff (`diff -u OLD NEW`).
# Output: one line per changed input line, prefixed `  + ` (added) or `  - `
# (removed). Context and hunk markers are suppressed.
#
# NR <= 2 drops the `--- file1` / `+++ file2` headers by position rather than
# by regex. A regex like `/^--- /` would false-match a deleted content line
# whose text began with `-- ` (the diff would render it as `--- ...`) and
# silently eat that change from the preview. Position-based skipping is safe
# because unified-diff always emits exactly those two header lines first.
NR <= 2 { next }
/^@@/ { next }
/^-/ { print "  - " substr($0, 2); next }
/^\+/ { print "  + " substr($0, 2); next }
