#!/usr/bin/env bash
# Smoke test for mutation-test.sh — usage errors, dirty-tree refusal, red-baseline abort,
# caught/survived/flaky/timeout/error classification, restore-by-copy on every exit path,
# and the final byte-identical + green-again verification.
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

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Fixed-mtime reference for the leak check at the end. $TMP_ROOT's own mtime keeps changing
# as session directories are created inside it, so it cannot serve as the reference.
STAMP="$TMP_ROOT/.stamp"
: > "$STAMP"

# Must not depend on a counter: these are called from `$( )`, whose subshell cannot advance
# a variable in the parent, so every case would reuse one directory.
new_session_dir() {
    mktemp -d "$TMP_ROOT/session.XXXXXX"
}

# Portable in-place edit. `sed -i` is GNU-only (BSD/macOS needs `-i ''`), and writing the
# temp file inside the repo would show up as untracked drift in the very check under test.
subst() {
    local expr="$1" file="$2" tmp="$TMP_ROOT/subst.$$"
    sed "$expr" "$file" > "$tmp"
    cp "$tmp" "$file"
    rm -f "$tmp"
}

# Build a git repo containing src/calc.sh, plus a runner OUTSIDE the repo that tests only
# `add` — `mul` is deliberately uncovered.
fresh_repo() {
    local d="$TMP_ROOT/repo.$$.$RANDOM"
    git init -q -b main "$d"
    mkdir -p "$d/src"
    cat > "$d/src/calc.sh" <<'CALC'
add() { echo $(( $1 + $2 )); }
mul() { echo $(( $1 * $2 )); }
CALC
    (
        set -e
        cd "$d"
        git config user.email "test@example.com"
        git config user.name "Test"
        # Keep bytes on disk identical to bytes in the index — the whole suite reasons about
        # byte-for-byte restoration, and CRLF translation would muddy that.
        git config core.autocrlf false
        # A developer with global commit signing would otherwise get a half-built fixture.
        git config commit.gpgsign false
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
[ "\$(add 2 3)" = "5" ] || exit 1
exit 0
RUNNER
}

hash_of() { git -C "$1" hash-object "$2"; }

# 0. The script parses. CLAUDE.md names bash -n as the cheapest test tier.
bash -n "$SUT" || fail "mutation-test.sh has a syntax error"
pass "bash -n passes on the script under test"

# 1. No arguments prints usage and exits 2.
rc=0; bash "$SUT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 with no subcommand, got $rc"
pass "usage error with no subcommand (exit 2)"

# 2. Unknown subcommand exits 2.
rc=0; bash "$SUT" bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 for unknown subcommand, got $rc"
pass "unknown subcommand rejected (exit 2)"

# 3. --help exits 0 and writes usage to STDOUT.
out="$(bash "$SUT" --help 2>/dev/null)"
echo "$out" | grep -q "usage:" || fail "expected --help to print usage on stdout"
pass "--help prints usage on stdout, exit 0"

# 4. begin without --test-cmd, and without a target selector, are usage errors.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run4.sh"
write_runner "$runner" "$repo"
rc=0; ( cd "$repo" && bash "$SUT" begin --file src/calc.sh ) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 when --test-cmd is missing, got $rc"
rc=0; ( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" ) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 when no target selector is given, got $rc"
pass "begin rejects a missing --test-cmd and a missing target selector"

# 5. A trailing flag with no value is a usage error WITH a diagnostic — not a silent exit 1.
rc=0
err="$( ( cd "$repo" && bash "$SUT" begin --file src/calc.sh --test-cmd ) 2>&1 >/dev/null )" || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 for a value-less trailing flag, got $rc"
echo "$err" | grep -q "requires a value" || fail "expected a 'requires a value' diagnostic, got: $err"
pass "value-less trailing flag gives a diagnostic and exit 2, not a silent failure"

# 6. --timeout validation.
for bad in abc 0 -5 ""; do
    rc=0
    ( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh --timeout "$bad" ) \
        >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || fail "expected exit 2 for --timeout '$bad', got $rc"
done
pass "--timeout rejects non-numeric, zero, negative, and empty values"

# 7. Dirty working tree is refused with exit 4; --allow-dirty overrides.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run7.sh"
write_runner "$runner" "$repo"
echo "# dirt" >> "$repo/src/calc.sh"
rc=0
( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh \
    --session-dir "$(new_session_dir)" ) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] || fail "expected exit 4 on dirty tree, got $rc"
out="$( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh \
    --allow-dirty --session-dir "$(new_session_dir)" 2>/dev/null )"
echo "$out" | grep -q "^BASELINE=green$" || fail "expected green baseline with --allow-dirty, got: $out"
pass "dirty tree refused (exit 4); --allow-dirty proceeds"

# 8. An UNTRACKED file also counts as dirty (README claims 'refuses a dirty working tree').
repo="$(fresh_repo)"
runner="$TMP_ROOT/run8.sh"
write_runner "$runner" "$repo"
: > "$repo/stray.txt"
rc=0
( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh \
    --session-dir "$(new_session_dir)" ) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] || fail "expected untracked file to count as dirty, got $rc"
pass "untracked files count as a dirty tree"

# 9. A red baseline aborts with exit 3 before anything is mutated, and still prints SESSION=
#    so the caller can clean up the backup it already made.
repo="$(fresh_repo)"
red_runner="$TMP_ROOT/red.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$red_runner"
rc=0
out="$( cd "$repo" && bash "$SUT" begin --test-cmd "bash $red_runner" --file src/calc.sh \
    --session-dir "$(new_session_dir)" 2>/dev/null )" || rc=$?
[ "$rc" -eq 3 ] || fail "expected exit 3 on a red baseline, got $rc"
echo "$out" | grep -q "^BASELINE=red$" || fail "expected BASELINE=red, got: $out"
echo "$out" | grep -q "^SESSION=" || fail "expected SESSION= even on a red baseline, got: $out"
pass "red baseline aborts (exit 3) and still reports its session"

# 10. Happy-path begin: SESSION/TARGETS/BASELINE, backup outside the repo.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run10.sh"
write_runner "$runner" "$repo"
session="$(new_session_dir)"
out="$( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh \
    --session-dir "$session" 2>/dev/null )"
echo "$out" | grep -q "^SESSION=$session$" || fail "expected SESSION=$session, got: $out"
echo "$out" | grep -q "^TARGETS=1$" || fail "expected TARGETS=1, got: $out"
echo "$out" | grep -q "^BASELINE=green$" || fail "expected BASELINE=green, got: $out"
[ -f "$session/backup/src/calc.sh" ] || fail "expected backup at \$session/backup/src/calc.sh"
pass "begin backs up targets to a session outside the repo and proves a green baseline"

# 11. run with no mutation applied is refused (would otherwise file a false survivor).
rc=0
( cd "$repo" && bash "$SUT" run --session "$session" --name no-op ) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "expected exit 3 when no mutation is applied, got $rc"
pass "run refuses when no target file differs from the backup"

# 12. A mutation the suite covers is CAUGHT, restored byte-identically, and the report
#     records WHICH failure signal fired.
before_hash="$(hash_of "$repo" src/calc.sh)"
subst 's/\$1 + \$2/$1 - $2/' "$repo/src/calc.sh"
out="$( cd "$repo" && bash "$SUT" run --session "$session" --name break-add \
    --description "add() subtracts instead of adding" 2>/dev/null )"
echo "$out" | grep -q "^RESULT=caught$" || fail "expected RESULT=caught for break-add, got: $out"
echo "$out" | grep -q "^RESTORED=yes$" || fail "expected RESTORED=yes, got: $out"
[ "$(hash_of "$repo" src/calc.sh)" = "$before_hash" ] \
    || fail "source file was not restored byte-identically after a caught mutation"
pass "covered mutation is caught and the file is restored byte-identically"

# 13. A mutation the suite does NOT cover SURVIVES, with a repro that actually re-applies it.
subst 's/\$1 \* \$2/$1 + $2/' "$repo/src/calc.sh"
out="$( cd "$repo" && bash "$SUT" run --session "$session" --name break-mul \
    --description "mul() adds instead of multiplying" 2>/dev/null )"
echo "$out" | grep -q "^RESULT=survived$" || fail "expected RESULT=survived for break-mul, got: $out"
[ "$(hash_of "$repo" src/calc.sh)" = "$before_hash" ] \
    || fail "source file was not restored after a surviving mutation"
[ -f "$session/mutations/break-mul/repro.sh" ] || fail "expected a repro.sh for the survivor"
bash "$session/mutations/break-mul/repro.sh" >/dev/null 2>&1 \
    || fail "expected the survivor's repro.sh to reproduce a green suite"
# Assert the MUTATED line specifically. Grepping for '$1 + $2' alone is vacuous: add() always
# contains it, so the check would pass even if repro.sh copied nothing.
grep -q 'mul() { echo $(( $1 + $2' "$repo/src/calc.sh" \
    || fail "expected repro.sh to re-apply the mutation to mul()"
[ "$(hash_of "$repo" src/calc.sh)" != "$before_hash" ] \
    || fail "repro.sh should leave the tree mutated"
cp "$session/backup/src/calc.sh" "$repo/src/calc.sh"
[ "$(hash_of "$repo" src/calc.sh)" = "$before_hash" ] || fail "manual restore failed"
pass "uncovered mutation survives and its repro.sh re-applies the exact mutation"

# 14. A duplicate mutation name is refused AND the tree is restored — the caller applied the
#     mutation before run was ever invoked, so no error path may leave it behind.
subst 's/\$1 \* \$2/$1 + $2/' "$repo/src/calc.sh"
rc=0
( cd "$repo" && bash "$SUT" run --session "$session" --name break-mul ) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 on a duplicate mutation name, got $rc"
[ "$(hash_of "$repo" src/calc.sh)" = "$before_hash" ] \
    || fail "duplicate-name refusal left the tree mutated"
pass "duplicate mutation name is refused AND the tree is restored"

# 15. An invalid --name is refused and also restores. Includes the multi-line case, which a
#     line-oriented `grep -E '^...$'` check would wrongly accept.
subst 's/\$1 \* \$2/$1 + $2/' "$repo/src/calc.sh"
rc=0
( cd "$repo" && bash "$SUT" run --session "$session" --name "has space" ) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 for a name with a space, got $rc"
rc=0
( cd "$repo" && bash "$SUT" run --session "$session" --name "$(printf 'ok\n../escape')" ) \
    >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 for a multi-line name, got $rc"
[ ! -e "$session/escape" ] && [ ! -e "$session/mutations/../escape" ] \
    || fail "multi-line name escaped the mutations directory"
[ "$(hash_of "$repo" src/calc.sh)" = "$before_hash" ] \
    || fail "invalid-name refusal left the tree mutated"
pass "invalid and multi-line --name are refused, with no traversal and no leftover mutation"

# 16. finish verifies the tree, re-runs the suite, and reports the survivor distinctly.
report="$( cd "$repo" && bash "$SUT" finish --session "$session" 2>/dev/null )"
echo "$report" | grep -q "^TREE_VERIFIED=yes$" || fail "expected TREE_VERIFIED=yes, got: $report"
echo "$report" | grep -q "^FINAL_SUITE=green$" || fail "expected FINAL_SUITE=green, got: $report"
echo "$report" | grep -q "1 caught, 1 survived" || fail "expected a 1-caught/1-survived tally, got: $report"
echo "$report" | grep -q "Needs attention" || fail "expected a survivors section"
echo "$report" | grep -q "break-mul\` survived" || fail "expected the survivor called out by name"
echo "$report" | grep -q "repro.sh" || fail "expected a reproduction command for the survivor"
echo "$report" | grep -q "Failure signal" || fail "expected a failure-signal column"
pass "finish verifies the tree, proves the suite green again, and reports survivors"

# 17. finish FAILS loudly when a target file does not match the backup.
echo "# leftover mutation" >> "$repo/src/calc.sh"
rc=0
report="$( cd "$repo" && bash "$SUT" finish --session "$session" 2>/dev/null )" || rc=$?
[ "$rc" -eq 5 ] || fail "expected exit 5 when the tree does not match the backup, got $rc"
echo "$report" | grep -q "^TREE_VERIFIED=no$" || fail "expected TREE_VERIFIED=no, got: $report"
cp "$session/backup/src/calc.sh" "$repo/src/calc.sh"
pass "finish fails loudly when the tree is not byte-identical to the backup"

# 18. status reports without verifying, and never claims the tree was checked.
out="$( cd "$repo" && bash "$SUT" status --session "$session" 2>/dev/null )"
echo "$out" | grep -q "Mutation test report" || fail "expected status to render the report"
echo "$out" | grep -q "^VERIFICATION=not-run$" || fail "expected VERIFICATION=not-run from status"
if echo "$out" | grep -q "TREE_VERIFIED"; then
    fail "status must not emit TREE_VERIFIED"
fi
pass "status renders the report without claiming verification"

# 19. A suite whose own run writes an untracked cache must NOT be reported as drift. The
#     porcelain snapshot is taken after the baseline run precisely so this is the normal case.
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
pass "artifacts created by the baseline run are not mistaken for campaign drift"

# 20. --allow-test-artifacts forgives UNTRACKED drift but never TRACKED drift.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run20.sh"
write_runner "$runner" "$repo"
session="$(new_session_dir)"
( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh \
    --session-dir "$session" >/dev/null 2>&1 ) || fail "begin failed in the artifacts case"
: > "$repo/coverage.out"                       # untracked drift appearing after begin
rc=0
report="$( cd "$repo" && bash "$SUT" finish --session "$session" --no-final-check 2>/dev/null )" || rc=$?
[ "$rc" -eq 5 ] || fail "expected exit 5 for untracked drift without the flag, got $rc"
report="$( cd "$repo" && bash "$SUT" finish --session "$session" --allow-test-artifacts \
    --no-final-check 2>/dev/null )" || fail "expected --allow-test-artifacts to forgive untracked drift"
echo "$report" | grep -q "^TREE_VERIFIED=partial$" || fail "expected TREE_VERIFIED=partial, got: $report"
rm -f "$repo/coverage.out"
printf 'note\n' > "$repo/tracked.txt"
( cd "$repo" && git add tracked.txt && git commit -q -m "add tracked file" )
# Re-baseline so the tracked file is part of the clean state, then modify it.
session="$(new_session_dir)"
( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh \
    --session-dir "$session" >/dev/null 2>&1 ) || fail "begin failed before the tracked-drift case"
printf 'modified\n' > "$repo/tracked.txt"
rc=0
report="$( cd "$repo" && bash "$SUT" finish --session "$session" --allow-test-artifacts \
    --no-final-check 2>/dev/null )" || rc=$?
[ "$rc" -eq 5 ] || fail "expected --allow-test-artifacts to STILL fail on tracked drift, got $rc"
echo "$report" | grep -q "^TREE_VERIFIED=no$" || fail "expected TREE_VERIFIED=no for tracked drift, got: $report"
( cd "$repo" && git checkout -- tracked.txt )
pass "--allow-test-artifacts forgives untracked drift only, never tracked drift"

# 21. A relative --file is resolved against the INVOCATION directory, not the repo root.
#     A shadowing file at the root is what turns this from a confusing error into a silently
#     wrong target.
repo="$(fresh_repo)"
printf 'root() { echo root; }\n' > "$repo/calc.sh"
( cd "$repo" && git add calc.sh && git commit -q -m "add a shadowing root calc.sh" )
runner="$TMP_ROOT/run21.sh"
write_runner "$runner" "$repo"
session="$(new_session_dir)"
out="$( cd "$repo/src" && bash "$SUT" begin --test-cmd "bash $runner" --file calc.sh \
    --session-dir "$session" 2>/dev/null )"
echo "$out" | grep -q "^TARGETS=1$" || fail "expected TARGETS=1 from a subdirectory, got: $out"
[ -f "$session/backup/src/calc.sh" ] \
    || fail "relative --file from src/ must target src/calc.sh, not the root calc.sh"
[ ! -f "$session/backup/calc.sh" ] || fail "relative --file wrongly targeted the root calc.sh"
pass "a relative --file from a subdirectory targets the file the caller named"

# 22. A suite that IGNORES SIGTERM must be reported as a timeout, not a catch. GNU timeout
#     returns 137 (SIGKILL) rather than 124 in this case.
repo="$(fresh_repo)"
before_hash="$(hash_of "$repo" src/calc.sh)"
stub_runner="$TMP_ROOT/stub22.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_runner"
session="$(new_session_dir)"
# The timeout must comfortably exceed process-spawn overhead (~3s under Git Bash on Windows),
# or the trivially-green baseline is itself killed. The run below then costs this plus the
# script's 10s SIGKILL grace, twice, because a timeout is always re-run.
( cd "$repo" && bash "$SUT" begin --test-cmd "bash $stub_runner" --file src/calc.sh \
    --timeout 8 --session-dir "$session" >/dev/null 2>&1 ) || fail "begin failed for the ignore-TERM case"
printf '#!/usr/bin/env bash\ntrap "" TERM\nsleep 60\n' > "$stub_runner"
subst 's/\$1 + \$2/$1 - $2/' "$repo/src/calc.sh"
out="$( cd "$repo" && bash "$SUT" run --session "$session" --name ignores-term \
    --description "suite ignores SIGTERM and must be SIGKILLed" 2>/dev/null )"
echo "$out" | grep -q "^RESULT=timeout$" \
    || fail "a SIGTERM-ignoring hang must be RESULT=timeout, not a catch; got: $out"
[ "$(hash_of "$repo" src/calc.sh)" = "$before_hash" ] || fail "tree left mutated after a 137 timeout"
pass "a suite that ignores SIGTERM is a timeout, not a false catch"

# 23. A test command that cannot be invoked is an 'error', never a catch.
repo="$(fresh_repo)"
before_hash="$(hash_of "$repo" src/calc.sh)"
stub_runner="$TMP_ROOT/stub23.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_runner"
session="$(new_session_dir)"
( cd "$repo" && bash "$SUT" begin --test-cmd "bash $stub_runner" --file src/calc.sh \
    --session-dir "$session" >/dev/null 2>&1 ) || fail "begin failed for the harness-error case"
printf '#!/usr/bin/env bash\nexit 127\n' > "$stub_runner"
subst 's/\$1 + \$2/$1 - $2/' "$repo/src/calc.sh"
out="$( cd "$repo" && bash "$SUT" run --session "$session" --name harness-broken 2>/dev/null )"
echo "$out" | grep -q "^RESULT=error$" || fail "expected RESULT=error for an uninvokable command, got: $out"
[ "$(hash_of "$repo" src/calc.sh)" = "$before_hash" ] || fail "tree left mutated after a harness error"
pass "an uninvokable test command is an error, not a catch"

# 24. --rerun-caught: a re-run that ALSO fails stays 'caught' (the common real outcome);
#     a re-run that passes becomes 'flaky'.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run24.sh"
write_runner "$runner" "$repo"
session="$(new_session_dir)"
( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh \
    --rerun-caught --session-dir "$session" >/dev/null 2>&1 ) || fail "begin failed in the rerun case"
subst 's/\$1 + \$2/$1 - $2/' "$repo/src/calc.sh"
out="$( cd "$repo" && bash "$SUT" run --session "$session" --name stays-caught 2>/dev/null )"
echo "$out" | grep -q "^RESULT=caught$" || fail "a reliably failing mutation must stay caught, got: $out"
counter="$TMP_ROOT/flaky24.count"
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

# 25. --verify-green catches a tree that is no longer green after a restore.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run25.sh"
write_runner "$runner" "$repo"
session="$(new_session_dir)"
( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh \
    --verify-green --session-dir "$session" >/dev/null 2>&1 ) || fail "begin failed in the verify-green case"
subst 's/\$1 \* \$2/$1 + $2/' "$repo/src/calc.sh"
out="$( cd "$repo" && bash "$SUT" run --session "$session" --name green-again 2>/dev/null )"
echo "$out" | grep -q "^GREEN_AGAIN=yes$" || fail "expected GREEN_AGAIN=yes, got: $out"
pass "--verify-green proves the suite is green again before the next mutation"

# 26. --session-dir inside the repository is rejected, and nothing is created there.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run26.sh"
write_runner "$runner" "$repo"
rc=0
( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh \
    --session-dir "$repo/.mutation-session" ) >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "expected refusal of a session directory inside the repository"
[ ! -e "$repo/.mutation-session" ] \
    || fail "a rejected --session-dir must not be created inside the repo"
pass "--session-dir inside the repo is rejected and leaves nothing behind"

# 27. --base resolves the change set; --exclude drops targets and says so; --files-from works.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run27.sh"
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
    --exclude '*.md' --session-dir "$(new_session_dir)" ) 2>&1 >/dev/null )"
echo "$err" | grep -q "excluding 'NOTES.md'" || fail "expected --exclude to announce the drop, got: $err"
out="$( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --base main \
    --exclude '*.md' --session-dir "$(new_session_dir)" 2>/dev/null )"
echo "$out" | grep -q "^TARGETS=1$" || fail "expected --exclude to drop NOTES.md, got: $out"
listfile="$TMP_ROOT/list27.txt"
printf '%s' "src/calc.sh" > "$listfile"     # deliberately no trailing newline
out="$( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --files-from "$listfile" \
    --session-dir "$(new_session_dir)" 2>/dev/null )"
echo "$out" | grep -q "^TARGETS=1$" || fail "expected --files-from to keep an entry with no trailing newline, got: $out"
pass "--base, --exclude (announced), and --files-from resolve targets correctly"

# 28. A symlinked target is skipped rather than silently 'restored' through the link.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run28.sh"
write_runner "$runner" "$repo"
if ln -s src/calc.sh "$repo/link.sh" 2>/dev/null && [ -L "$repo/link.sh" ]; then
    ( cd "$repo" && git add link.sh && git commit -q -m "add symlink" )
    err="$( ( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" \
        --file src/calc.sh --file link.sh --session-dir "$(new_session_dir)" ) 2>&1 >/dev/null )"
    echo "$err" | grep -q "symlink" || fail "expected a symlink target to be skipped with a note, got: $err"
    pass "symlinked targets are skipped, not restored through the link"
else
    rm -f "$repo/link.sh"
    pass "symlink case skipped (this platform does not create real symlinks)"
fi

# 29. The script must never undo a mutation with git — that would silently discard
#     uncommitted work in the same file and leave the campaign looking green. The guard
#     strips comments and echo/printf output, then rejects any remaining occurrence,
#     including `git -C <dir> checkout` and `git clean`/`git reset --hard`.
stripped="$TMP_ROOT/sut-stripped.sh"
sed -e 's/#.*$//' -e 's/echo .*//' -e 's/printf .*//' "$SUT" > "$stripped"
if grep -qE 'git([[:space:]]+(-C|--git-dir|-c)[[:space:]]+[^[:space:]]+)*[[:space:]]+(checkout|restore|stash|clean)' "$stripped"; then
    fail "mutation-test.sh must not execute git checkout/restore/stash/clean"
fi
if grep -qE 'git[[:space:]]+reset' "$stripped"; then
    fail "mutation-test.sh must not execute git reset"
fi
pass "no git checkout/restore/stash/clean/reset is used to undo a mutation"

# 30. No session directories were leaked into TMPDIR: every case passed --session-dir.
leaked="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'mutation-test-*' -newer "$STAMP" 2>/dev/null | wc -l | tr -d ' ')"
[ "$leaked" = "0" ] || fail "$leaked session directories leaked into TMPDIR during this run"
pass "no session directories leaked into TMPDIR"

echo "all smoke tests passed"
