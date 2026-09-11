#!/usr/bin/env bash
# Smoke test for mutation-test.sh — usage errors, dirty-tree refusal, baseline enforcement,
# caught/survived/flaky/timeout/error classification, restore-by-copy on every exit path,
# out-of-target contamination detection, and the final verification.
#
# Uses real local git repos as fixtures with a tiny shell "library" and a test runner that
# exercises only half of it — so mutating the covered half is caught and mutating the
# uncovered half survives, which is the whole point of the tool.
#
# Every case passes --session-dir under $TMP_ROOT so sessions are cleaned up with the
# fixtures rather than accumulating source backups in TMPDIR.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUT="$SCRIPT_DIR/mutation-test.sh"

CASES=0
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { CASES=$((CASES + 1)); echo "ok: $*"; }
skip() { echo "SKIP: $*"; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Fixed-mtime reference for the leak check at the end. $TMP_ROOT's own mtime keeps changing
# as session directories are created inside it, so it cannot serve as the reference.
STAMP="$TMP_ROOT/.stamp"
: > "$STAMP"

# Must not depend on a counter: these are called from `$( )`, whose subshell cannot advance
# a variable in the parent, so every case would reuse one directory. mktemp also avoids the
# $RANDOM-in-a-subshell collision hazard on older bash.
new_session_dir() {
    mktemp -d "$TMP_ROOT/session.XXXXXX"
}

# Portable in-place edit. `sed -i` is GNU-only (BSD/macOS needs `-i ''`), and writing the
# temp file inside the repo would show up as untracked drift in the very check under test.
subst() {
    local expr="$1" file="$2" tmp
    tmp="$(mktemp "$TMP_ROOT/subst.XXXXXX")"
    sed "$expr" "$file" > "$tmp"
    cp "$tmp" "$file"
    rm -f "$tmp"
}

# Build a git repo containing src/calc.sh and src/helper.sh, plus a runner OUTSIDE the repo
# that tests only `add` — `mul` is deliberately uncovered.
fresh_repo() {
    local d
    d="$(mktemp -d "$TMP_ROOT/repo.XXXXXX")"
    git init -q -b main "$d"
    mkdir -p "$d/src"
    cat > "$d/src/calc.sh" <<'CALC'
add() { echo $(( $1 + $2 )); }
mul() { echo $(( $1 * $2 )); }
CALC
    printf 'helper() { echo help; }\n' > "$d/src/helper.sh"
    (
        set -e
        cd "$d"
        git config user.email "test@example.com"
        git config user.name "Test"
        # Keep bytes on disk identical to bytes in the index — the whole suite reasons about
        # byte-for-byte restoration, and CRLF translation would muddy that.
        git config core.autocrlf false
        # A developer with global commit signing or global hooks would otherwise get a
        # half-built fixture and a confusing downstream failure.
        git config commit.gpgsign false
        git config core.hooksPath ""
        git add -A
        git commit -q -m "seed"
    ) || { echo "FAIL: fixture repo setup failed" >&2; exit 1; }
    printf '%s' "$d"
}

# A runner script living outside the repo, so swapping it mid-campaign never dirties the tree.
write_runner() {
    local path="$1" repo="$2"
    cat > "$path" <<RUNNER
#!/usr/bin/env bash
set -uo pipefail
. "$repo/src/calc.sh"
if [ "\$(add 2 3)" != "5" ]; then
    echo "AssertionError: add(2,3) expected 5"
    exit 1
fi
exit 0
RUNNER
}

hash_of() { git -C "$1" hash-object "$2"; }

# Convenience: begin a session on a fresh repo, echo "repo|session".
begin_ok() {
    local repo="$1" runner="$2" session="$3"; shift 3
    ( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh \
        --session-dir "$session" "$@" >/dev/null 2>&1 ) || fail "begin failed: $*"
}

# 0. The script parses. Cheapest possible tier, and it catches a broken edit instantly.
bash -n "$SUT" || fail "mutation-test.sh has a syntax error"
pass "bash -n passes on the script under test"

# 1. Usage errors: no subcommand, unknown subcommand, --help to stdout.
rc=0; bash "$SUT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 with no subcommand, got $rc"
rc=0; bash "$SUT" bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 for unknown subcommand, got $rc"
out="$(bash "$SUT" --help 2>/dev/null)"
echo "$out" | grep -q "usage:" || fail "expected --help to print usage on stdout"
pass "usage errors exit 2; --help prints usage on stdout"

# 2. begin without --test-cmd, and without a target selector, are usage errors.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run2.sh"
write_runner "$runner" "$repo"
rc=0; ( cd "$repo" && bash "$SUT" begin --file src/calc.sh ) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 when --test-cmd is missing, got $rc"
rc=0; ( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" ) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 when no target selector is given, got $rc"
pass "begin rejects a missing --test-cmd and a missing target selector"

# 3. A trailing flag with no value is a usage error WITH a diagnostic — not a silent exit 1.
rc=0
err="$( ( cd "$repo" && bash "$SUT" begin --file src/calc.sh --test-cmd ) 2>&1 >/dev/null )" || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 for a value-less trailing flag, got $rc"
echo "$err" | grep -q "requires a value" || fail "expected a 'requires a value' diagnostic, got: $err"
pass "value-less trailing flag gives a diagnostic and exit 2, not a silent failure"

# 4. --timeout validation, including the multi-line value a line-oriented grep would accept.
for bad in abc 0 -5 "" "$(printf '8\nrubbish')"; do
    rc=0
    ( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh --timeout "$bad" ) \
        >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || fail "expected exit 2 for --timeout '$bad', got $rc"
done
pass "--timeout rejects non-numeric, zero, negative, empty, and multi-line values"

# 5. Dirty tree is refused (exit 4); --allow-dirty overrides; untracked counts as dirty even
#    when the repo sets status.showUntrackedFiles=no.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run5.sh"
write_runner "$runner" "$repo"
echo "# dirt" >> "$repo/src/calc.sh"
rc=0
( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh \
    --session-dir "$(new_session_dir)" ) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] || fail "expected exit 4 on dirty tree, got $rc"
out="$( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh \
    --allow-dirty --session-dir "$(new_session_dir)" 2>/dev/null )"
echo "$out" | grep -q "^BASELINE=green$" || fail "expected green baseline with --allow-dirty, got: $out"
repo="$(fresh_repo)"
runner="$TMP_ROOT/run5b.sh"
write_runner "$runner" "$repo"
( cd "$repo" && git config status.showUntrackedFiles no )
: > "$repo/stray.txt"
rc=0
( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh \
    --session-dir "$(new_session_dir)" ) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] || fail "untracked file must count as dirty even with showUntrackedFiles=no, got $rc"
pass "dirty tree refused (exit 4); --allow-dirty overrides; showUntrackedFiles=no cannot hide dirt"

# 6. A red baseline aborts with exit 3, prints SESSION= so the backup can be cleaned up, and
#    the resulting session is REFUSED by run/finish/status — it never had a green baseline.
repo="$(fresh_repo)"
red_runner="$TMP_ROOT/red.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$red_runner"
session="$(new_session_dir)"
rc=0
out="$( cd "$repo" && bash "$SUT" begin --test-cmd "bash $red_runner" --file src/calc.sh \
    --session-dir "$session" 2>/dev/null )" || rc=$?
[ "$rc" -eq 3 ] || fail "expected exit 3 on a red baseline, got $rc"
echo "$out" | grep -q "^BASELINE=red$" || fail "expected BASELINE=red, got: $out"
echo "$out" | grep -q "^SESSION=" || fail "expected SESSION= even on a red baseline, got: $out"
rc=0
( cd "$repo" && bash "$SUT" run --session "$session" --name x ) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "expected 'run' to refuse a session with no green baseline, got $rc"
for verb in finish status; do
    rc=0
    ( cd "$repo" && bash "$SUT" "$verb" --session "$session" ) >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 3 ] || fail "expected '$verb' to refuse a session with no green baseline, got $rc"
done
pass "red baseline aborts (exit 3); run/finish/status refuse that session"

# 7. Happy-path begin.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run7.sh"
write_runner "$runner" "$repo"
session="$(new_session_dir)"
out="$( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh \
    --session-dir "$session" 2>/dev/null )"
echo "$out" | grep -q "^SESSION=$session$" || fail "expected SESSION=$session, got: $out"
echo "$out" | grep -q "^TARGETS=1$" || fail "expected TARGETS=1, got: $out"
echo "$out" | grep -q "^BASELINE=green$" || fail "expected BASELINE=green, got: $out"
[ -f "$session/backup/src/calc.sh" ] || fail "expected backup at \$session/backup/src/calc.sh"
pass "begin backs up targets to a session outside the repo and proves a green baseline"

# 8. run with no mutation applied is refused (would otherwise file a false survivor).
rc=0
( cd "$repo" && bash "$SUT" run --session "$session" --name no-op ) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "expected exit 3 when no mutation is applied, got $rc"
pass "run refuses when no target file differs from the backup"

# 9. A covered mutation is CAUGHT, restored byte-identically, and its failure signal is
#    captured — not just the table header.
before_hash="$(hash_of "$repo" src/calc.sh)"
subst 's/\$1 + \$2/$1 - $2/' "$repo/src/calc.sh"
out="$( cd "$repo" && bash "$SUT" run --session "$session" --name break-add \
    --description "add() subtracts instead of adding" 2>/dev/null )"
echo "$out" | grep -q "^RESULT=caught$" || fail "expected RESULT=caught for break-add, got: $out"
echo "$out" | grep -q "^RESTORED=yes$" || fail "expected RESTORED=yes, got: $out"
[ "$(hash_of "$repo" src/calc.sh)" = "$before_hash" ] \
    || fail "source file was not restored byte-identically after a caught mutation"
grep -q "AssertionError" "$session/results.tsv" \
    || fail "expected the failing assertion to be captured in results.tsv, got: $(cat "$session/results.tsv")"
pass "covered mutation is caught, restored byte-identically, and its assertion is captured"

# 10. An uncovered mutation SURVIVES, with a repro that re-applies exactly it.
subst 's/\$1 \* \$2/$1 + $2/' "$repo/src/calc.sh"
out="$( cd "$repo" && bash "$SUT" run --session "$session" --name break-mul \
    --description "mul() adds instead of multiplying" 2>/dev/null )"
echo "$out" | grep -q "^RESULT=survived$" || fail "expected RESULT=survived for break-mul, got: $out"
[ "$(hash_of "$repo" src/calc.sh)" = "$before_hash" ] \
    || fail "source file was not restored after a surviving mutation"
bash "$session/mutations/break-mul/repro.sh" >/dev/null 2>&1 \
    || fail "expected the survivor's repro.sh to reproduce a green suite"
# Assert the MUTATED line specifically. Grepping for '$1 + $2' alone is vacuous: add() always
# contains it, so the check would pass even if repro.sh copied nothing.
grep -q 'mul() { echo $(( $1 + $2' "$repo/src/calc.sh" \
    || fail "expected repro.sh to re-apply the mutation to mul()"
cp "$session/backup/src/calc.sh" "$repo/src/calc.sh"
[ "$(hash_of "$repo" src/calc.sh)" = "$before_hash" ] || fail "manual restore failed"
pass "uncovered mutation survives and its repro.sh re-applies the exact mutation"

# 11. A duplicate name, an invalid name, and an unknown FLAG are all refused AND restore the
#     tree — the caller mutated it before run was ever invoked, so no error path may keep it.
expect_run_refused() {
    local label="$1"; shift
    subst 's/\$1 \* \$2/$1 + $2/' "$repo/src/calc.sh"
    [ "$(hash_of "$repo" src/calc.sh)" != "$before_hash" ] || fail "setup: mutation for [$label] did not apply"
    local rc=0
    ( cd "$repo" && bash "$SUT" run --session "$session" "$@" ) >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || fail "expected exit 2 for [$label], got $rc"
    [ "$(hash_of "$repo" src/calc.sh)" = "$before_hash" ] || fail "[$label] exited without restoring the tree"
}
expect_run_refused "duplicate name" --name break-mul
expect_run_refused "name with a space" --name "has space"
expect_run_refused "multi-line name" --name "$(printf 'ok\n../escape')"
expect_run_refused "reserved name" --name ".."
expect_run_refused "unknown flag" --name ok --bogus-flag
expect_run_refused "value-less flag" --name
[ ! -e "$session/escape" ] || fail "multi-line name escaped the mutations directory"
pass "duplicate, invalid, multi-line names and unknown flags all refuse AND restore"

# 12. finish verifies, re-runs the suite, and reports the survivor WITH its description.
report="$( cd "$repo" && bash "$SUT" finish --session "$session" 2>/dev/null )"
echo "$report" | grep -q "^TREE_VERIFIED=yes$" || fail "expected TREE_VERIFIED=yes, got: $report"
echo "$report" | grep -q "^FINAL_SUITE=green$" || fail "expected FINAL_SUITE=green, got: $report"
echo "$report" | grep -q "1 caught, 1 survived" || fail "expected a 1-caught/1-survived tally"
echo "$report" | grep -q "break-mul\` survived\*\* — mul() adds instead of multiplying" \
    || fail "the survivor's DESCRIPTION must survive into the report bullet, got: $(echo "$report" | grep survived)"
echo "$report" | grep -q "| \`break-mul\` | survived | .* | — | mul() adds instead of multiplying |" \
    || fail "survivor row must keep its description in the last column, got: $(echo "$report" | grep 'break-mul |')"
echo "$report" | grep -q "| \`break-add\` | caught | .* | AssertionError.* | add() subtracts instead of adding |" \
    || fail "caught row must carry both a signal and its description, got: $(echo "$report" | grep 'break-add |')"
pass "finish verifies, proves the suite green again, and keeps every column aligned"

# 13. finish FAILS loudly when a target file does not match the backup, and banners the report.
echo "# leftover mutation" >> "$repo/src/calc.sh"
rc=0
report="$( cd "$repo" && bash "$SUT" finish --session "$session" 2>/dev/null )" || rc=$?
[ "$rc" -eq 5 ] || fail "expected exit 5 when the tree does not match the backup, got $rc"
echo "$report" | grep -q "^TREE_VERIFIED=no$" || fail "expected TREE_VERIFIED=no, got: $report"
echo "$report" | grep -q "UNVERIFIED" || fail "expected the report body to be bannered UNVERIFIED"
echo "$report" | grep -q "^FINAL_SUITE=skipped-tree-unverified$" \
    || fail "expected the final suite run to be skipped and labelled as such"
cp "$session/backup/src/calc.sh" "$repo/src/calc.sh"
pass "finish fails loudly, banners the report, and distinguishes why the suite was skipped"

# 14. status reports without verifying, and never claims the tree was checked.
out="$( cd "$repo" && bash "$SUT" status --session "$session" 2>/dev/null )"
echo "$out" | grep -q "Mutation test report" || fail "expected status to render the report"
echo "$out" | grep -q "^VERIFICATION=not-run$" || fail "expected VERIFICATION=not-run from status"
if echo "$out" | grep -q "TREE_VERIFIED"; then
    fail "status must not emit TREE_VERIFIED"
fi
pass "status renders the report without claiming verification"

# 15. A FINAL_SUITE=red on a byte-identical tree must NOT be reported as a restore problem.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run15.sh"
write_runner "$runner" "$repo"
session="$(new_session_dir)"
begin_ok "$repo" "$runner" "$session"
printf '#!/usr/bin/env bash\nexit 1\n' > "$runner"   # environment turns red for its own reasons
rc=0
report="$( cd "$repo" && bash "$SUT" finish --session "$session" 2>/dev/null )" || rc=$?
[ "$rc" -eq 6 ] || fail "expected exit 6 (tree verified, suite red), got $rc"
echo "$report" | grep -q "^TREE_VERIFIED=yes$" \
    || fail "a byte-identical tree must still verify when the suite is red, got: $report"
echo "$report" | grep -q "^FINAL_SUITE=red$" || fail "expected FINAL_SUITE=red"
if echo "$report" | grep -q "Restore manually"; then
    fail "must not tell the user to restore a tree that is provably restored"
fi
pass "a red closing suite is reported independently of tree verification (exit 6)"

# 16. An edit OUTSIDE the target set is detected — those files are never backed up.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run16.sh"
write_runner "$runner" "$repo"
session="$(new_session_dir)"
begin_ok "$repo" "$runner" "$session"
subst 's/\$1 \* \$2/$1 + $2/' "$repo/src/calc.sh"
printf 'helper() { echo POLLUTED; }\n' > "$repo/src/helper.sh"
rc=0
err="$( ( cd "$repo" && bash "$SUT" run --session "$session" --name polluter ) 2>&1 >/dev/null )" || rc=$?
[ "$rc" -eq 5 ] || fail "expected exit 5 when a non-target file was edited, got $rc"
echo "$err" | grep -q "outside the target set" || fail "expected an out-of-target diagnostic, got: $err"
echo "$err" | grep -q "helper.sh" || fail "expected the polluted file to be named, got: $err"
( cd "$repo" && git checkout -- src/helper.sh )
pass "an edit outside the target set is detected and named"

# 17. A relative --session is resolved against the invocation directory, not the repo root.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run17.sh"
write_runner "$runner" "$repo"
session="$(new_session_dir)"
begin_ok "$repo" "$runner" "$session"
before_hash="$(hash_of "$repo" src/calc.sh)"
subst 's/\$1 \* \$2/$1 + $2/' "$repo/src/calc.sh"
out="$( cd "$repo" && bash "$SUT" run --session "../$(basename "$session")" --name rel-session 2>/dev/null )"
echo "$out" | grep -q "^RESULT=survived$" || fail "expected a relative --session to resolve, got: $out"
[ "$(hash_of "$repo" src/calc.sh)" = "$before_hash" ] || fail "relative --session run left the tree mutated"
[ -d "$session/mutations/rel-session" ] || fail "artifacts did not land in the real session directory"
[ ! -d "$repo/mutations" ] || fail "a relative --session resolved inside the repository"
pass "a relative --session resolves against the caller's directory, not the repo root"

# 18. A session belonging to another repository is refused.
other="$(fresh_repo)"
rc=0
err="$( ( cd "$other" && bash "$SUT" finish --session "$session" ) 2>&1 >/dev/null )" || rc=$?
[ "$rc" -ne 0 ] || fail "expected a session from another repo to be refused"
echo "$err" | grep -q "belongs to" || fail "expected a clear cross-repo diagnostic, got: $err"
pass "a session from a different repository is refused"

# 19. A relative --file is resolved against the INVOCATION directory, not the repo root.
repo="$(fresh_repo)"
printf 'root() { echo root; }\n' > "$repo/calc.sh"
( cd "$repo" && git add calc.sh && git commit -q -m "add a shadowing root calc.sh" )
runner="$TMP_ROOT/run19.sh"
write_runner "$runner" "$repo"
session="$(new_session_dir)"
out="$( cd "$repo/src" && bash "$SUT" begin --test-cmd "bash $runner" --file calc.sh \
    --session-dir "$session" 2>/dev/null )"
echo "$out" | grep -q "^TARGETS=1$" || fail "expected TARGETS=1 from a subdirectory, got: $out"
[ -f "$session/backup/src/calc.sh" ] \
    || fail "relative --file from src/ must target src/calc.sh, not the root calc.sh"
[ ! -f "$session/backup/calc.sh" ] || fail "relative --file wrongly targeted the root calc.sh"
pass "a relative --file from a subdirectory targets the file the caller named"

# 20. A suite that writes an untracked cache is not drift; --allow-test-artifacts forgives
#     untracked drift that appears later, but never tracked drift.
repo="$(fresh_repo)"
cache_runner="$TMP_ROOT/cache.sh"
cat > "$cache_runner" <<CACHE
#!/usr/bin/env bash
mkdir -p "$repo/.pytest_cache"
date > "$repo/.pytest_cache/stamp"
exit 0
CACHE
session="$(new_session_dir)"
( cd "$repo" && bash "$SUT" begin --test-cmd "bash $cache_runner" --file src/calc.sh \
    --session-dir "$session" >/dev/null 2>&1 ) || fail "begin failed for the cache-writing suite"
report="$( cd "$repo" && bash "$SUT" finish --session "$session" 2>/dev/null )" \
    || fail "finish must not fail because the suite wrote its own cache"
echo "$report" | grep -q "^TREE_VERIFIED=yes$" \
    || fail "a cache created by the baseline run must not count as drift, got: $report"
repo="$(fresh_repo)"
runner="$TMP_ROOT/run20.sh"
write_runner "$runner" "$repo"
session="$(new_session_dir)"
begin_ok "$repo" "$runner" "$session"
: > "$repo/coverage.out"
rc=0
( cd "$repo" && bash "$SUT" finish --session "$session" --no-final-check ) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 5 ] || fail "expected exit 5 for untracked drift without the flag, got $rc"
report="$( cd "$repo" && bash "$SUT" finish --session "$session" --allow-test-artifacts \
    --no-final-check 2>/dev/null )" || fail "expected --allow-test-artifacts to forgive untracked drift"
echo "$report" | grep -q "^TREE_VERIFIED=partial$" || fail "expected TREE_VERIFIED=partial, got: $report"
echo "$report" | grep -q "^FINAL_SUITE=skipped-by-request$" || fail "expected the skip reason to be reported"
rm -f "$repo/coverage.out"
printf 'note\n' > "$repo/tracked.txt"
( cd "$repo" && git add tracked.txt && git commit -q -m "add tracked file" )
session="$(new_session_dir)"
begin_ok "$repo" "$runner" "$session"
printf 'modified\n' > "$repo/tracked.txt"
rc=0
report="$( cd "$repo" && bash "$SUT" finish --session "$session" --allow-test-artifacts \
    --no-final-check 2>/dev/null )" || rc=$?
[ "$rc" -eq 5 ] || fail "expected --allow-test-artifacts to STILL fail on tracked drift, got $rc"
echo "$report" | grep -q "^TREE_VERIFIED=no$" || fail "expected TREE_VERIFIED=no for tracked drift"
( cd "$repo" && git checkout -- tracked.txt )
pass "--allow-test-artifacts forgives untracked drift only, never tracked drift"

# 21. A tracked file that was ALREADY dirty at baseline is content-checked, not just status-
#     checked: porcelain would show the same ' M' line either way.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run21.sh"
write_runner "$runner" "$repo"
printf 'helper() { echo predirty; }\n' > "$repo/src/helper.sh"
session="$(new_session_dir)"
begin_ok "$repo" "$runner" "$session" --allow-dirty
printf 'helper() { echo CHANGED-AGAIN; }\n' > "$repo/src/helper.sh"
rc=0
report="$( cd "$repo" && bash "$SUT" finish --session "$session" --no-final-check 2>/dev/null )" || rc=$?
[ "$rc" -eq 5 ] || fail "content drift in an already-dirty tracked file must fail, got $rc"
echo "$report" | grep -q "content changed in already-modified tracked file" \
    || fail "expected the content-hash check to name the file, got: $report"
pass "content drift in an already-dirty tracked file is detected"

# 22. SIGTERM during a run restores the tree, exits 143, and records NOTHING. A handler that
#     merely returned would let the script resume and invent a verdict.
repo="$(fresh_repo)"
slow_runner="$TMP_ROOT/slow.sh"
printf '#!/usr/bin/env bash\nsleep 25\nexit 0\n' > "$slow_runner"
session="$(new_session_dir)"
( cd "$repo" && bash "$SUT" begin --test-cmd "bash $slow_runner" --file src/calc.sh \
    --session-dir "$session" --timeout 120 >/dev/null 2>&1 ) || fail "begin failed for the signal case"
before_hash="$(hash_of "$repo" src/calc.sh)"
subst 's/\$1 \* \$2/$1 + $2/' "$repo/src/calc.sh"
( cd "$repo" && bash "$SUT" run --session "$session" --name interrupted ) \
    >"$TMP_ROOT/sig.out" 2>"$TMP_ROOT/sig.err" &
runpid=$!
sleep 8
kill -TERM "$runpid" 2>/dev/null || true
rc=0
wait "$runpid" || rc=$?
[ "$rc" -eq 143 ] || fail "expected exit 143 after SIGTERM, got $rc"
[ "$(hash_of "$repo" src/calc.sh)" = "$before_hash" ] || fail "SIGTERM left the tree mutated"
[ ! -s "$session/results.tsv" ] || fail "an interrupted run must record no result, got: $(cat "$session/results.tsv")"
if grep -q "RESULT=" "$TMP_ROOT/sig.out"; then
    fail "an interrupted run must not print a verdict"
fi
pass "SIGTERM restores the tree, exits 143, and records no verdict"

# 23. A suite that IGNORES SIGTERM is a timeout, not a catch (GNU timeout returns 137).
repo="$(fresh_repo)"
before_hash="$(hash_of "$repo" src/calc.sh)"
stub_runner="$TMP_ROOT/stub23.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_runner"
session="$(new_session_dir)"
# The timeout must comfortably exceed process-spawn overhead (~3s under Git Bash on Windows),
# or the trivially-green baseline is itself killed. The run below then costs this plus the
# script's 10s SIGKILL grace, twice, because a timeout is always re-run.
( cd "$repo" && bash "$SUT" begin --test-cmd "bash $stub_runner" --file src/calc.sh \
    --timeout 8 --session-dir "$session" >/dev/null 2>&1 ) || fail "begin failed for the ignore-TERM case"
printf '#!/usr/bin/env bash\ntrap "" TERM\nsleep 60\n' > "$stub_runner"
subst 's/\$1 + \$2/$1 - $2/' "$repo/src/calc.sh"
out="$( cd "$repo" && bash "$SUT" run --session "$session" --name ignores-term 2>/dev/null )"
echo "$out" | grep -q "^RESULT=timeout$" \
    || fail "a SIGTERM-ignoring hang must be RESULT=timeout, not a catch; got: $out"
[ "$(hash_of "$repo" src/calc.sh)" = "$before_hash" ] || fail "tree left mutated after a 137 timeout"
pass "a suite that ignores SIGTERM is a timeout, not a false catch"

# 24. A test command that cannot be invoked is an 'error', never a catch.
repo="$(fresh_repo)"
before_hash="$(hash_of "$repo" src/calc.sh)"
stub_runner="$TMP_ROOT/stub24.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_runner"
session="$(new_session_dir)"
begin_ok "$repo" "$stub_runner" "$session"
printf '#!/usr/bin/env bash\nexit 127\n' > "$stub_runner"
subst 's/\$1 + \$2/$1 - $2/' "$repo/src/calc.sh"
out="$( cd "$repo" && bash "$SUT" run --session "$session" --name harness-broken 2>/dev/null )"
echo "$out" | grep -q "^RESULT=error$" || fail "expected RESULT=error for an uninvokable command, got: $out"
[ "$(hash_of "$repo" src/calc.sh)" = "$before_hash" ] || fail "tree left mutated after a harness error"
pass "an uninvokable test command is an error, not a catch"

# 25. --rerun-caught: a re-run that ALSO fails stays 'caught'; one that passes becomes 'flaky'.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run25.sh"
write_runner "$runner" "$repo"
session="$(new_session_dir)"
begin_ok "$repo" "$runner" "$session" --rerun-caught
subst 's/\$1 + \$2/$1 - $2/' "$repo/src/calc.sh"
out="$( cd "$repo" && bash "$SUT" run --session "$session" --name stays-caught 2>/dev/null )"
echo "$out" | grep -q "^RESULT=caught$" || fail "a reliably failing mutation must stay caught, got: $out"
counter="$TMP_ROOT/flaky25.count"
: > "$counter"
cat > "$runner" <<FLAKY
#!/usr/bin/env bash
if [ ! -s "$counter" ]; then
    echo used > "$counter"
    exit 1
fi
exit 0
FLAKY
subst 's/\$1 \* \$2/$1 + $2/' "$repo/src/calc.sh"
out="$( cd "$repo" && bash "$SUT" run --session "$session" --name flaky-case \
    --description "intermittent failure, not a real catch" 2>/dev/null )"
echo "$out" | grep -q "^RESULT=flaky$" || fail "expected RESULT=flaky with --rerun-caught, got: $out"
report="$( cd "$repo" && bash "$SUT" status --session "$session" 2>/dev/null )"
echo "$report" | grep -q "was flaky — inconclusive" || fail "expected the flaky result marked inconclusive"
pass "--rerun-caught keeps a reliable failure caught and reclassifies an intermittent one"

# 26. --verify-green proves the tree is green again after each restore.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run26.sh"
write_runner "$runner" "$repo"
session="$(new_session_dir)"
begin_ok "$repo" "$runner" "$session" --verify-green
subst 's/\$1 \* \$2/$1 + $2/' "$repo/src/calc.sh"
out="$( cd "$repo" && bash "$SUT" run --session "$session" --name green-again 2>/dev/null )"
echo "$out" | grep -q "^GREEN_AGAIN=yes$" || fail "expected GREEN_AGAIN=yes, got: $out"
pass "--verify-green proves the suite is green again before the next mutation"

# 27. --session-dir inside the repository is rejected, and nothing is created there.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run27.sh"
write_runner "$runner" "$repo"
rc=0
( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh \
    --session-dir "$repo/.mutation-session" ) >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "expected refusal of a session directory inside the repository"
[ ! -e "$repo/.mutation-session" ] \
    || fail "a rejected --session-dir must not be created inside the repo"
pass "--session-dir inside the repo is rejected and leaves nothing behind"

# 28. --base resolves the change set; --exclude drops targets and announces both a match and
#     a miss; --files-from tolerates a missing trailing newline and CRLF.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run28.sh"
write_runner "$runner" "$repo"
( cd "$repo" \
    && git checkout -q -b feature \
    && printf 'sub() { echo $(( $1 - $2 )); }\n' >> src/calc.sh \
    && printf 'notes\n' > NOTES.md \
    && git add -A \
    && git commit -q -m "add sub and notes" )
out="$( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --base main \
    --session-dir "$(new_session_dir)" 2>/dev/null )"
echo "$out" | grep -q "^TARGETS=2$" || fail "expected --base to resolve 2 changed files, got: $out"
err="$( ( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --base main \
    --exclude '*.md' --exclude '*.nomatch' --session-dir "$(new_session_dir)" ) 2>&1 >/dev/null )"
echo "$err" | grep -q "excluding 'NOTES.md'" || fail "expected --exclude to announce the drop, got: $err"
echo "$err" | grep -q "matched no target" || fail "expected an --exclude that matched nothing to be reported"
listfile="$TMP_ROOT/list28.txt"
printf 'src/calc.sh\r' > "$listfile"     # CRLF-style, and no trailing newline
out="$( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --files-from "$listfile" \
    --session-dir "$(new_session_dir)" 2>/dev/null )"
echo "$out" | grep -q "^TARGETS=1$" || fail "expected --files-from to handle CRLF and no trailing newline, got: $out"
pass "--base, --exclude (match and miss announced), and --files-from resolve targets correctly"

# 29. A symlinked target is skipped rather than silently 'restored' through the link.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run29.sh"
write_runner "$runner" "$repo"
if ln -s src/calc.sh "$repo/link.sh" 2>/dev/null && [ -L "$repo/link.sh" ]; then
    ( cd "$repo" && git add link.sh && git commit -q -m "add symlink" )
    err="$( ( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" \
        --file src/calc.sh --file link.sh --session-dir "$(new_session_dir)" ) 2>&1 >/dev/null )"
    echo "$err" | grep -q "symlink" || fail "expected a symlink target to be skipped with a note, got: $err"
    pass "symlinked targets are skipped, not restored through the link"
else
    rm -f "$repo/link.sh"
    skip "symlink case (this platform does not create real symlinks)"
fi

# 30. The script must never undo a mutation with git. The guard strips comments and
#     echo/printf output first, so it cannot be satisfied by quoting, and it covers
#     `git -C <dir> checkout` as well as clean/reset.
stripped="$TMP_ROOT/sut-stripped.sh"
sed -e 's/#.*$//' -e 's/echo .*//' -e 's/printf .*//' "$SUT" > "$stripped"
if grep -qE 'git([[:space:]]+(-C|--git-dir|-c)[[:space:]]+[^[:space:]]+)*[[:space:]]+(checkout|restore|stash|clean|reset)' "$stripped"; then
    fail "mutation-test.sh must not execute git checkout/restore/stash/clean/reset"
fi
pass "no git checkout/restore/stash/clean/reset is used to undo a mutation"

# 31. No session directories were leaked into TMPDIR: every case passed --session-dir.
leaked="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'mutation-test-*' -newer "$STAMP" 2>/dev/null | wc -l | tr -d ' ')"
[ "$leaked" = "0" ] || fail "$leaked session directories leaked into TMPDIR during this run"
pass "no session directories leaked into TMPDIR"

# A deleted or short-circuited case would otherwise be invisible.
EXPECTED_CASES=31
[ "$CASES" -ge "$((EXPECTED_CASES - 1))" ] \
    || fail "only $CASES cases ran, expected about $EXPECTED_CASES — did a case get skipped?"
echo "all smoke tests passed ($CASES cases)"
