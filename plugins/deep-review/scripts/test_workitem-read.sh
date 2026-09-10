#!/usr/bin/env bash
# Smoke test for workitem-read.sh.
# Invoke: bash scripts/test_workitem-read.sh
#
# Coverage: syntax, usage errors, work-item id validation, organization
# validation (the security surface — see below), the HTML-to-text rendering,
# the cp1252 decode fallback, and az failure handling.
#
# WHY THE ORG ASSERTIONS ARE THE IMPORTANT ONES. This script exists so a
# constrained runner can allow ONE named script instead of allowing `az`, which
# cannot be allowed safely: argparse honours the last repeated option, so
# `--org <pinned> --org https://evil/x` matches any prefix rule and ships the
# token off-org. That safety rests entirely on the organization coming from the
# ENVIRONMENT and never from an argument. The cases below assert exactly that —
# if a future edit adds an --org flag, they fail.
#
# `az` is STUBBED on PATH so the tests run offline and deterministically, and a
# sentinel asserts the stub is in use. The stub mimics the real command's OUTPUT
# SHAPE, which is what the script depends on: `az boards work-item show -o json`
# emits one JSON object with `id` and a `fields` map whose Description and
# AcceptanceCriteria values are HTML.
#
#   STUB_MODE=ok        well-formed success (default)
#   STUB_MODE=fail      non-zero exit, as for a 404 or an auth failure
#   STUB_MODE=cp1252    valid JSON whose em dash is a bare 0x97 byte, which is
#                       what `az` really emits on Windows
#   STUB_MODE=empty     exit 0 with no output
#   STUB_MODE=minimal   a work item with no description and no criteria
#   STUB_ARGS_FILE=<f>  record argv, to prove which org was passed
#
# NOT covered: real az authentication and live network behavior. The output
# shape was verified by hand against a real work item (AB#8421).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/workitem-read.sh"
ORG="https://dev.azure.com/example"

fail=0
pass=0

TEST_TMPDIR=""
trap 'if [ -n "$TEST_TMPDIR" ]; then rm -rf "$TEST_TMPDIR"; fi' EXIT INT TERM

assert_exit() {
    local want="$1" got="$2" label="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1)); echo "  PASS $label"
    else
        fail=$((fail + 1)); echo "  FAIL $label: want exit $want, got $got"
    fi
}

assert_contains() {
    local needle="$1" out="$2" label="$3"
    case "$out" in
        *"$needle"*) pass=$((pass + 1)); echo "  PASS $label" ;;
        *) fail=$((fail + 1)); echo "  FAIL $label: output missing '$needle'"; echo "    got: $out" ;;
    esac
}

assert_not_contains() {
    local needle="$1" out="$2" label="$3"
    case "$out" in
        *"$needle"*) fail=$((fail + 1)); echo "  FAIL $label: output unexpectedly contains '$needle'"; echo "    got: $out" ;;
        *) pass=$((pass + 1)); echo "  PASS $label" ;;
    esac
}

# Exact whole-line match. assert_contains is a substring test, so a rendering
# bug that runs two fields onto one line still passes it — which is precisely
# the defect found by hand during development (a heading after a </ul> lost its
# line break). Every line-shape assertion should use this instead.
assert_line() {
    local needle="$1" out="$2" label="$3"
    case "
$out
" in
        *"
$needle
"*) pass=$((pass + 1)); echo "  PASS $label" ;;
        *) fail=$((fail + 1)); echo "  FAIL $label: no line equal to '$needle'"; echo "    got: $out" ;;
    esac
}

# Self-test, because a broken matcher turns every assertion using it into a
# silent pass — the same blind spot as an untested code path.
assert_line "b" "$(printf 'a\nb\nc')" "assert_line matches an interior line"
assert_line "a" "$(printf 'a\nb')" "assert_line matches the first line"

# mktemp is required: a Windows-style path (C:/...) in PATH does NOT shadow a
# real CLI under Git Bash, which would silently run the live `az` — against a
# real organization — instead of the stub. mktemp yields a POSIX path.
TEST_TMPDIR=$(mktemp -d) || { echo "mktemp -d failed; cannot run tests" >&2; exit 1; }
[ -n "$TEST_TMPDIR" ] || { echo "mktemp -d returned empty; refusing to continue" >&2; exit 1; }

STUB_DIR="$TEST_TMPDIR/bin"
mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/az" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_ARGS_FILE:-}" ] && echo "$@" >> "$STUB_ARGS_FILE"
case "${STUB_MODE:-ok}" in
    fail)    echo "TF401232: work item does not exist" >&2; exit 1 ;;
    empty)   exit 0 ;;
    minimal)
        printf '%s' '{"id":7,"fields":{"System.WorkItemType":"Bug","System.State":"New","System.Title":"Bare item"}}'
        ;;
    cp1252)
        # A real az on Windows writes its stdout in the legacy code page and
        # ignores PYTHONIOENCODING, so an em dash arrives as a lone 0x97 byte —
        # not valid UTF-8. printf, not echo, to emit the byte literally.
        printf '{"id":8421,"fields":{"System.Title":"Read stories\x97reliably","System.Description":"<p>One\x97two</p>"}}'
        ;;
    *)
        printf '%s' '{"id":8421,"fields":{"System.WorkItemType":"User Story","System.State":"Active","System.Title":"Read linked stories","System.Description":"<div>Automated reviews cannot read the story.</div><p>Second paragraph &amp; an entity.</p>","Microsoft.VSTS.Common.AcceptanceCriteria":"<ul><li>The link renders as a link</li><li>The override runs</li></ul><h3>Why this is tracked</h3><p>Paper trail.</p>"}}'
        ;;
esac
STUB
chmod +x "$STUB_DIR/az"
export PATH="$STUB_DIR:$PATH"

# ── Suite ────────────────────────────────────────────────────────────

echo "== sentinel =="
assert_contains "$STUB_DIR" "$(command -v az)" "az stub is on PATH (not the live CLI)"

echo "== syntax =="
bash -n "$SCRIPT" 2>/dev/null
assert_exit 0 $? "script parses"

echo "== usage =="
out=$(bash "$SCRIPT" 2>&1); rc=$?
assert_exit 1 "$rc" "no arguments exits 1"
assert_contains "usage:" "$out" "no arguments prints usage"

out=$(bash "$SCRIPT" 8421 extra 2>&1); rc=$?
assert_exit 1 "$rc" "two arguments exits 1"
assert_contains "usage:" "$out" "two arguments prints usage"

echo "== work-item id validation =="
for bad in 0100 0 abc 8421x '8421 --org' '' 12345678901; do
    out=$(DEEP_REVIEW_ADO_ORG="$ORG" bash "$SCRIPT" "$bad" 2>&1); rc=$?
    assert_exit 1 "$rc" "id '$bad' is rejected"
done
assert_contains "no leading zero" "$out" "rejection explains the id shape"

# The upper boundary is inclusive: 10 digits is a real ADO id shape and must
# still work. A test that only checks the negative would pass on an off-by-one
# that rejected every long id.
out=$(DEEP_REVIEW_ADO_ORG="$ORG" bash "$SCRIPT" 1234567890 2>&1); rc=$?
assert_exit 0 "$rc" "a 10-digit id is accepted"

echo "== organization validation (the security surface) =="
out=$(env -u DEEP_REVIEW_ADO_ORG bash "$SCRIPT" 8421 2>&1); rc=$?
assert_exit 1 "$rc" "missing org exits 1"
assert_contains "never from an argument" "$out" "missing-org message states where the org comes from"

out=$(DEEP_REVIEW_ADO_ORG="" bash "$SCRIPT" 8421 2>&1); rc=$?
assert_exit 1 "$rc" "empty org exits 1"

out=$(DEEP_REVIEW_ADO_ORG="http://evil.example" bash "$SCRIPT" 8421 2>&1); rc=$?
assert_exit 1 "$rc" "plain http org is rejected"
assert_contains "absolute https:// URL" "$out" "http rejection names the requirement"

out=$(DEEP_REVIEW_ADO_ORG="dev.azure.com/example" bash "$SCRIPT" 8421 2>&1); rc=$?
assert_exit 1 "$rc" "scheme-less org is rejected"

out=$(DEEP_REVIEW_ADO_ORG='$(System.CollectionUri)' bash "$SCRIPT" 8421 2>&1); rc=$?
assert_exit 1 "$rc" "unexpanded pipeline macro is rejected"
assert_contains "unexpanded variable" "$out" "macro rejection names the cause"

# There must be NO way to pass an organization positionally. If a future edit
# adds one, the id validator no longer sees a bare id and this starts passing
# an org through argv — the exact hole the script was written to close.
out=$(DEEP_REVIEW_ADO_ORG="$ORG" bash "$SCRIPT" 8421 "https://evil.example" 2>&1); rc=$?
assert_exit 1 "$rc" "an org cannot be smuggled in as a second argument"

# The org actually handed to az is the pinned one, exactly once.
ARGS_FILE="$TEST_TMPDIR/args.txt"
STUB_ARGS_FILE="$ARGS_FILE" DEEP_REVIEW_ADO_ORG="$ORG" bash "$SCRIPT" 8421 >/dev/null 2>&1
args=$(cat "$ARGS_FILE" 2>/dev/null)
assert_contains "--org $ORG" "$args" "az receives the organization from the environment"
assert_exit 1 "$(grep -c -- '--org' "$ARGS_FILE" 2>/dev/null | tr -d ' ')" "az receives exactly one --org occurrence"
assert_contains "--id 8421" "$args" "az receives the requested id"

echo "== rendering =="
out=$(DEEP_REVIEW_ADO_ORG="$ORG" bash "$SCRIPT" 8421 2>&1); rc=$?
assert_exit 0 "$rc" "happy path exits 0"
assert_line "id: 8421" "$out" "id is emitted"
assert_line "type: User Story" "$out" "type is emitted"
assert_line "state: Active" "$out" "state is emitted"
assert_line "title: Read linked stories" "$out" "title is emitted"
assert_line "Description:" "$out" "description is labelled"
assert_line "Acceptance criteria:" "$out" "acceptance criteria are labelled"
assert_not_contains "<" "$out" "no HTML tags survive"
assert_not_contains "&amp;" "$out" "HTML entities are unescaped"
assert_contains "& an entity" "$out" "the unescaped entity reads correctly"

# One criterion per line, because the caller is asked to enumerate them one per
# line. <li> soup on a single line is the shape that made this necessary.
assert_line "  - The link renders as a link" "$out" "first criterion is its own line"
assert_line "  - The override runs" "$out" "second criterion is its own line"

# Block boundaries. Closing tags alone lost the break between a list and the
# heading that followed it, running "Why this is tracked" onto the last
# criterion — found by hand against the real work item, so it is pinned here.
assert_line "Why this is tracked" "$out" "a heading after a list starts its own line"
assert_line "Automated reviews cannot read the story." "$out" "a div is a block boundary"
assert_line "Second paragraph & an entity." "$out" "a following p is its own line"

echo "== decoding =="
# 0x97 is meaningless as UTF-8; strict decoding lost the entire story over one
# character, which is worse than the mangled character it was avoiding.
out=$(STUB_MODE=cp1252 DEEP_REVIEW_ADO_ORG="$ORG" bash "$SCRIPT" 8421 2>&1); rc=$?
assert_exit 0 "$rc" "cp1252 payload still exits 0"
assert_contains "Read stories" "$out" "cp1252 payload is decoded, not abandoned"
assert_line "title: Read stories—reliably" "$out" "the em dash survives as an em dash"
assert_not_contains "$(printf '\357\277\275')" "$out" "no replacement characters in the output"

echo "== failure handling =="
out=$(STUB_MODE=fail DEEP_REVIEW_ADO_ORG="$ORG" bash "$SCRIPT" 8421 2>&1); rc=$?
assert_exit 1 "$rc" "az failure exits 1"
assert_contains "could not read work item 8421" "$out" "az failure names the id"
assert_not_contains "TF401232" "$out" "az's own stderr is not passed through"

out=$(STUB_MODE=empty DEEP_REVIEW_ADO_ORG="$ORG" bash "$SCRIPT" 8421 2>&1); rc=$?
assert_exit 1 "$rc" "empty az output exits 1"

echo "== sparse work items =="
# A work item with no description and no criteria is a normal state, not an
# error: the reviewer should still learn the title and be able to say the story
# carries no criteria to grade against.
out=$(STUB_MODE=minimal DEEP_REVIEW_ADO_ORG="$ORG" bash "$SCRIPT" 7 2>&1); rc=$?
assert_exit 0 "$rc" "a work item with no body exits 0"
assert_line "title: Bare item" "$out" "title is still emitted"
assert_not_contains "Description:" "$out" "an absent description is omitted, not printed empty"
assert_not_contains "Acceptance criteria:" "$out" "absent criteria are omitted, not printed empty"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
