#!/usr/bin/env bash
# Smoke test for mutation-test.sh — usage errors, dirty-tree refusal, red-baseline abort,
# caught/survived classification, timeout handling, flake filtering, restore-by-copy,
# and the final byte-identical verification.
#
# Uses a real local git repo as the fixture with a tiny shell "library" and a test runner
# that exercises only half of it — so mutating the covered half is caught and mutating the
# uncovered half survives, which is the whole point of the tool.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUT="$SCRIPT_DIR/mutation-test.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

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
        cd "$d"
        git config user.email "test@example.com"
        git config user.name "Test"
        # Keep bytes on disk identical to bytes in the index — the whole suite reasons about
        # byte-for-byte restoration, and CRLF translation would muddy that.
        git config core.autocrlf false
        : > .allow-push-main
        git add -A
        git commit -q -m "seed"
    )
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

# 1. No arguments prints usage and exits non-zero.
if bash "$SUT" >/dev/null 2>&1; then
    fail "expected non-zero exit with no subcommand"
fi
pass "usage error with no subcommand"

# 2. begin without --test-cmd is a usage error.
repo="$(fresh_repo)"
if ( cd "$repo" && bash "$SUT" begin --file src/calc.sh >/dev/null 2>&1 ); then
    fail "expected usage error when --test-cmd is missing"
fi
pass "begin without --test-cmd is rejected"

# 3. begin without any target selector is a usage error.
runner="$TMP_ROOT/run.$$.sh"
write_runner "$runner" "$repo"
if ( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" >/dev/null 2>&1 ); then
    fail "expected usage error when neither --base nor --file is given"
fi
pass "begin without a target selector is rejected"

# 4. Dirty working tree is refused with exit 4.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run4.$$.sh"
write_runner "$runner" "$repo"
echo "# dirt" >> "$repo/src/calc.sh"
rc=0
( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh >/dev/null 2>&1 ) || rc=$?
[ "$rc" -eq 4 ] || fail "expected exit 4 on dirty tree, got $rc"
pass "dirty working tree refused (exit 4)"

# 5. --allow-dirty overrides the refusal.
out="$( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh --allow-dirty 2>/dev/null )"
echo "$out" | grep -q "^BASELINE=green$" || fail "expected green baseline with --allow-dirty, got: $out"
pass "--allow-dirty proceeds on a dirty tree"

# 6. A red baseline aborts with exit 3 before anything is mutated.
repo="$(fresh_repo)"
red_runner="$TMP_ROOT/red.$$.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$red_runner"
rc=0
out="$( cd "$repo" && bash "$SUT" begin --test-cmd "bash $red_runner" --file src/calc.sh 2>/dev/null )" || rc=$?
[ "$rc" -eq 3 ] || fail "expected exit 3 on a red baseline, got $rc"
echo "$out" | grep -q "^BASELINE=red$" || fail "expected BASELINE=red, got: $out"
pass "red baseline aborts before mutating (exit 3)"

# 7. Happy-path begin: prints SESSION/TARGETS/BASELINE, backs up outside the repo.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run7.$$.sh"
write_runner "$runner" "$repo"
out="$( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh 2>/dev/null )"
session="$(echo "$out" | sed -n 's/^SESSION=//p')"
[ -n "$session" ] || fail "expected SESSION= in begin output, got: $out"
echo "$out" | grep -q "^TARGETS=1$" || fail "expected TARGETS=1, got: $out"
echo "$out" | grep -q "^BASELINE=green$" || fail "expected BASELINE=green, got: $out"
[ -f "$session/backup/src/calc.sh" ] || fail "expected backup at \$session/backup/src/calc.sh"
case "$session" in
    "$repo"/*) fail "session directory must live outside the repository";;
esac
pass "begin backs up targets to a session outside the repo and proves a green baseline"

# 8. run with no mutation applied is refused (would otherwise file a false survivor).
rc=0
( cd "$repo" && bash "$SUT" run --session "$session" --name no-op >/dev/null 2>&1 ) || rc=$?
[ "$rc" -eq 3 ] || fail "expected exit 3 when no mutation is applied, got $rc"
pass "run refuses when no target file differs from the backup"

# 9. A mutation the suite covers is CAUGHT, and the file is restored byte-identically.
before_hash="$(git -C "$repo" hash-object src/calc.sh)"
sed -i 's/\$1 + \$2/$1 - $2/' "$repo/src/calc.sh"
out="$( cd "$repo" && bash "$SUT" run --session "$session" --name break-add \
    --description "add() subtracts instead of adding" 2>/dev/null )"
echo "$out" | grep -q "^RESULT=caught$" || fail "expected RESULT=caught for break-add, got: $out"
echo "$out" | grep -q "^RESTORED=yes$" || fail "expected RESTORED=yes, got: $out"
[ "$(git -C "$repo" hash-object src/calc.sh)" = "$before_hash" ] \
    || fail "source file was not restored byte-identically after a caught mutation"
pass "covered mutation is caught and the file is restored byte-identically"

# 10. A mutation the suite does NOT cover SURVIVES, with a working reproduction script.
sed -i 's/\$1 \* \$2/$1 + $2/' "$repo/src/calc.sh"
out="$( cd "$repo" && bash "$SUT" run --session "$session" --name break-mul \
    --description "mul() adds instead of multiplying" 2>/dev/null )"
echo "$out" | grep -q "^RESULT=survived$" || fail "expected RESULT=survived for break-mul, got: $out"
[ "$(git -C "$repo" hash-object src/calc.sh)" = "$before_hash" ] \
    || fail "source file was not restored after a surviving mutation"
[ -x "$session/mutations/break-mul/repro.sh" ] || [ -f "$session/mutations/break-mul/repro.sh" ] \
    || fail "expected a repro.sh for the survivor"
# The repro must actually re-apply the mutation and leave the suite green.
bash "$session/mutations/break-mul/repro.sh" >/dev/null 2>&1 \
    || fail "expected the survivor's repro.sh to reproduce a green suite"
grep -q '$1 + $2' "$repo/src/calc.sh" || fail "expected repro.sh to re-apply the mutation"
# repro.sh intentionally leaves the tree broken; restore by copy, as its own header instructs.
cp "$session/backup/src/calc.sh" "$repo/src/calc.sh"
[ "$(git -C "$repo" hash-object src/calc.sh)" = "$before_hash" ] || fail "manual restore failed"
pass "uncovered mutation survives and its repro.sh reproduces the survivor"

# 11. Duplicate mutation names are refused.
sed -i 's/\$1 \* \$2/$1 + $2/' "$repo/src/calc.sh"
rc=0
( cd "$repo" && bash "$SUT" run --session "$session" --name break-mul >/dev/null 2>&1 ) || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 on a duplicate mutation name, got $rc"
cp "$session/backup/src/calc.sh" "$repo/src/calc.sh"
pass "duplicate mutation name is refused"

# 12. finish verifies the tree and reports the survivor distinctly.
report="$( cd "$repo" && bash "$SUT" finish --session "$session" 2>/dev/null )"
echo "$report" | grep -q "^TREE_VERIFIED=yes$" || fail "expected TREE_VERIFIED=yes, got: $report"
echo "$report" | grep -q "1 caught, 1 survived" || fail "expected a 1-caught/1-survived tally, got: $report"
echo "$report" | grep -q "Needs attention" || fail "expected a survivors section"
echo "$report" | grep -q "break-mul\` survived" || fail "expected the survivor called out by name"
echo "$report" | grep -q "repro.sh" || fail "expected a reproduction command for the survivor"
pass "finish verifies the tree and reports survivors with a reproduction command"

# 13. finish FAILS loudly when the tree does not match the backup.
echo "# leftover mutation" >> "$repo/src/calc.sh"
rc=0
report="$( cd "$repo" && bash "$SUT" finish --session "$session" 2>/dev/null )" || rc=$?
[ "$rc" -eq 5 ] || fail "expected exit 5 when the tree does not match the backup, got $rc"
echo "$report" | grep -q "^TREE_VERIFIED=no$" || fail "expected TREE_VERIFIED=no, got: $report"
cp "$session/backup/src/calc.sh" "$repo/src/calc.sh"
pass "finish fails loudly when the tree is not byte-identical to the backup"

# 14. A hanging suite times out, and the tree is restored rather than left mutated.
repo="$(fresh_repo)"
before_hash="$(git -C "$repo" hash-object src/calc.sh)"
hang_runner="$TMP_ROOT/hang.$$.sh"
write_runner "$hang_runner" "$repo"
out="$( cd "$repo" && bash "$SUT" begin --test-cmd "bash $hang_runner" --file src/calc.sh --timeout 3 2>/dev/null )"
session="$(echo "$out" | sed -n 's/^SESSION=//p')"
[ -n "$session" ] || fail "expected a session for the timeout case"
printf '#!/usr/bin/env bash\nsleep 60\n' > "$hang_runner"
sed -i 's/\$1 + \$2/$1 - $2/' "$repo/src/calc.sh"
out="$( cd "$repo" && bash "$SUT" run --session "$session" --name hangs \
    --description "suite hangs under this mutation" 2>/dev/null )"
echo "$out" | grep -q "^RESULT=timeout$" || fail "expected RESULT=timeout, got: $out"
[ "$(git -C "$repo" hash-object src/calc.sh)" = "$before_hash" ] \
    || fail "tree was left mutated after a timeout"
pass "a hanging suite times out and the tree is restored, not left mutated"

# 15. --rerun-caught reclassifies a flaky failure so it can't masquerade as a catch.
repo="$(fresh_repo)"
flaky_runner="$TMP_ROOT/flaky.$$.sh"
counter="$TMP_ROOT/flaky.$$.count"
write_runner "$flaky_runner" "$repo"
out="$( cd "$repo" && bash "$SUT" begin --test-cmd "bash $flaky_runner" --file src/calc.sh --rerun-caught 2>/dev/null )"
session="$(echo "$out" | sed -n 's/^SESSION=//p')"
[ -n "$session" ] || fail "expected a session for the flake case"
# Fail the first invocation, pass every one after — a classic intermittent failure.
: > "$counter"
cat > "$flaky_runner" <<FLAKY
#!/usr/bin/env bash
if [ ! -s "$counter" ]; then
    echo used > "$counter"
    exit 1
fi
exit 0
FLAKY
sed -i 's/\$1 \* \$2/$1 + $2/' "$repo/src/calc.sh"
out="$( cd "$repo" && bash "$SUT" run --session "$session" --name flaky-case \
    --description "intermittent failure, not a real catch" 2>/dev/null )"
echo "$out" | grep -q "^RESULT=flaky$" || fail "expected RESULT=flaky with --rerun-caught, got: $out"
report="$( cd "$repo" && bash "$SUT" finish --session "$session" 2>/dev/null )"
echo "$report" | grep -q "was flaky" || fail "expected the flaky result surfaced under Needs attention"
pass "--rerun-caught reclassifies a flaky failure instead of counting it as a catch"

# 16. --session-dir inside the repository is rejected (it would perturb git status).
repo="$(fresh_repo)"
runner="$TMP_ROOT/run16.$$.sh"
write_runner "$runner" "$repo"
if ( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --file src/calc.sh \
        --session-dir "$repo/.mutation-session" >/dev/null 2>&1 ); then
    fail "expected refusal of a session directory inside the repository"
fi
pass "--session-dir inside the repo is rejected"

# 17. --base resolves the changed files instead of an explicit list.
repo="$(fresh_repo)"
runner="$TMP_ROOT/run17.$$.sh"
write_runner "$runner" "$repo"
( cd "$repo" \
    && git checkout -q -b feature \
    && printf 'sub() { echo $(( $1 - $2 )); }\n' >> src/calc.sh \
    && git commit -q -am "add sub" )
out="$( cd "$repo" && bash "$SUT" begin --test-cmd "bash $runner" --base main 2>/dev/null )"
echo "$out" | grep -q "^TARGETS=1$" || fail "expected --base to resolve 1 changed file, got: $out"
pass "--base resolves the change set from the diff"

# 18. The script must never undo a mutation with git — that would silently discard
#     uncommitted work in the same file and leave the campaign looking green.
#     The script names those commands in comments and in advice it prints, so the guard
#     filters out comment lines and echo/printf lines and asserts nothing executable remains.
offenders="$(grep -nE 'git[[:space:]]+(checkout|restore|stash)' "$SUT" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -vE '^[0-9]+:[[:space:]]*(echo|printf)[[:space:]]' || true)"
[ -z "$offenders" ] || fail "mutation-test.sh must not execute git checkout/restore/stash: $offenders"
pass "no git checkout/restore/stash is used to undo a mutation"

echo "all smoke tests passed"
