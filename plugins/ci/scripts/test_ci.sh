#!/usr/bin/env bash
# Smoke test for ci.sh: usage errors, init's refusals, substitution and pin, update's pin move,
# its refusals (no pin, a commit missing an action), and that a guard goes red when removed.
# Uses a local fake ci-recipes repository, offline.
#
#   bash plugins/ci/scripts/test_ci.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CI="$SCRIPT_DIR/ci.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

expect_exit() {
    local want="$1"; shift
    local got=0
    "$@" >"$TMP_ROOT/out" 2>&1 || got=$?
    [ "$got" = "$want" ] || { cat "$TMP_ROOT/out" >&2; fail "expected exit $want, got $got: $*"; }
}

# A fake ci-recipes with two commits: v1 has both actions, v2 drops pages-teardown.
SRC="$TMP_ROOT/ci-recipes"
git init -q -b main "$SRC"
mkdir -p "$SRC/templates" "$SRC/actions/pages-preview" "$SRC/actions/pages-teardown"
cat > "$SRC/templates/preview.yml" <<'EOF'
jobs:
  preview:
    steps:
      - uses: TimZander/ci-recipes/actions/pages-preview@__SHA__
        with:
          project-name: __PROJECT__
          directory: dist
          wrangler-version: '__WRANGLER__'
EOF
cat > "$SRC/templates/preview-teardown.yml" <<'EOF'
jobs:
  teardown:
    steps:
      - uses: TimZander/ci-recipes/actions/pages-teardown@__SHA__
        with:
          project-name: __PROJECT__
EOF
echo x > "$SRC/actions/pages-preview/action.yml"
echo x > "$SRC/actions/pages-teardown/action.yml"
git -C "$SRC" add -A && git -C "$SRC" commit -q -m v1
V1="$(git -C "$SRC" rev-parse HEAD)"
echo y >> "$SRC/actions/pages-preview/action.yml"
git -C "$SRC" commit -qam v1b
V1B="$(git -C "$SRC" rev-parse HEAD)"
git -C "$SRC" rm -q -r actions/pages-teardown && git -C "$SRC" commit -qm v2
V2="$(git -C "$SRC" rev-parse HEAD)"
git -C "$SRC" config uploadpack.allowAnySHA1InWant true
export CI_RECIPES_URL="$SRC"

repo() {
    local d="$TMP_ROOT/repo.$RANDOM$RANDOM"
    git init -q "$d"
    printf '%s' "$d"
}

# --- usage
expect_exit 2 bash "$CI"
expect_exit 2 bash "$CI" nonsense
expect_exit 2 bash "$CI" minutes
pass "usage errors exit 2"

R="$(repo)"; cd "$R"
expect_exit 2 bash "$CI" init --wrangler 4.1.0 --sha "$V1"
expect_exit 2 bash "$CI" init --project My_Site --wrangler 4.1.0 --sha "$V1"
expect_exit 2 bash "$CI" init --project site --wrangler 4 --sha "$V1"
expect_exit 2 bash "$CI" init --project site --wrangler '^4.1.0' --sha "$V1"
expect_exit 2 bash "$CI" init --project site --wrangler 4.1.0 --sha main
expect_exit 2 bash "$CI" init --project site --wrangler 4.1.0 --directory '../x' --sha "$V1"
expect_exit 2 bash "$CI" init --project site --wrangler 4.1.0 --directory 'a|b' --sha "$V1"
[ ! -e .github ] || fail "a refused init wrote something"
pass "init refuses bad project, ranges, branch pins and odd directories, writing nothing"

# --- init writes both, substituted and pinned
expect_exit 0 bash "$CI" init --project my-site --wrangler 4.142.0 --directory web/dist --sha "$V1"
grep -q "pages-preview@$V1" .github/workflows/preview.yml || fail "preview not pinned"
grep -q "pages-teardown@$V1" .github/workflows/preview-teardown.yml || fail "teardown not pinned"
grep -q "project-name: my-site" .github/workflows/preview.yml || fail "project not substituted"
grep -q "directory: web/dist" .github/workflows/preview.yml || fail "directory not substituted"
grep -q "wrangler-version: '4.142.0'" .github/workflows/preview.yml || fail "wrangler not substituted"
! grep -q '__[A-Z]*__' .github/workflows/*.yml || fail "a placeholder survived"
pass "init writes both workflows, substituted and pinned"

expect_exit 3 bash "$CI" init --project my-site --wrangler 4.142.0 --sha "$V1"
grep -q "Refused\|already exists" "$TMP_ROOT/out" || fail "no reason given"
pass "init refuses to overwrite"

mkdir sub && cd sub
expect_exit 3 bash "$CI" init --project x --wrangler 1.0.0 --sha "$V1"
cd ..
pass "init refuses outside the repository root"

# --- update
expect_exit 0 bash "$CI" update --sha "$V1B"
grep -q "pages-preview@$V1B" .github/workflows/preview.yml || fail "preview pin not moved"
grep -q "pages-teardown@$V1B" .github/workflows/preview-teardown.yml || fail "teardown pin not moved"
! grep -q "$V1" .github/workflows/*.yml || fail "an old pin survived"
pass "update moves every pin"

expect_exit 0 bash "$CI" update --sha "$V1B"
grep -q "already at" "$TMP_ROOT/out" || fail "no 'already at' on a second update"
pass "update is idempotent"

cp .github/workflows/preview-teardown.yml "$TMP_ROOT/before"
expect_exit 3 bash "$CI" update --sha "$V2"
cmp -s .github/workflows/preview-teardown.yml "$TMP_ROOT/before" || fail "a refused update changed a file"
grep -q "pages-preview@$V1B" .github/workflows/preview.yml || fail "a refused update changed preview.yml"
pass "update refuses a commit that dropped an action the repository uses, changing nothing"

# main moves on to v3, which has both actions again; update with no --sha must read it.
mkdir -p "$SRC/actions/pages-teardown" && echo z > "$SRC/actions/pages-teardown/action.yml"
git -C "$SRC" add -A && git -C "$SRC" commit -qm v3
V3="$(git -C "$SRC" rev-parse HEAD)"
expect_exit 0 bash "$CI" update
grep -q "pages-preview@$V3" .github/workflows/preview.yml || fail "update did not read main"
grep -q "pages-teardown@$V3" .github/workflows/preview-teardown.yml || fail "update did not read main"
pass "update with no --sha moves to ci-recipes' main"

R2="$(repo)"; cd "$R2"; mkdir -p .github/workflows; echo 'on: push' > .github/workflows/x.yml
expect_exit 3 bash "$CI" update --sha "$V1"
pass "update refuses a repository with no pin"

# --- positive control: the overwrite guard must be what refuses
NEUTERED="$TMP_ROOT/ci-neutered.sh"
sed 's/\[ -z "\$existing" \] || refuse/true || refuse/' "$CI" > "$NEUTERED"
cp "$SCRIPT_DIR/ci-recipes.pin" "$TMP_ROOT/ci-recipes.pin"
cd "$R"
got=0; bash "$NEUTERED" init --project my-site --wrangler 4.142.0 --sha "$V1" >/dev/null 2>&1 || got=$?
[ "$got" = 0 ] || fail "the neutered script still refused: the test is not testing the guard"
pass "positive control: with the overwrite guard removed, init overwrites"

# --- pin
pin="$(bash "$CI" pin)"
printf '%s' "$pin" | grep -Eq '^[0-9a-f]{40}$' || fail "pin is not a SHA: $pin"
pass "pin prints the default commit"

echo "all ci.sh tests passed"
