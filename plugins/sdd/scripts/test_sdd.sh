#!/usr/bin/env bash
# Smoke test for the sdd plugin's scripts: the installer (sdd-init.sh) and the
# scripts it installs into a repo (template/scripts/sdd/). Uses real git repos
# and a stub OpenSpec CLI, so it runs offline: the stub archives a change by
# moving its folder to archive/<date>-<name> and copying its delta specs over
# the main specs, and fails `validate` when a spec contains the word INVALID.
#
#   bash plugins/sdd/scripts/test_sdd.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT="$SCRIPT_DIR/sdd-init.sh"
T="$SCRIPT_DIR/../template/scripts/sdd"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

expect_exit() {
    local want="$1"; shift
    local got=0
    "$@" >"$TMP_ROOT/out" 2>&1 || got=$?
    [ "$got" = "$want" ] || { cat "$TMP_ROOT/out" >&2; fail "expected exit $want, got $got: $*"; }
}

fresh_repo() {
    local d="$TMP_ROOT/repo.$RANDOM$RANDOM"
    git init -q -b main "$d"
    git -C "$d" config user.email test@example.com
    git -C "$d" config user.name Test
    echo seed > "$d/README.md"
    git -C "$d" add README.md
    git -C "$d" commit -q -m seed
    printf '%s' "$d"
}

install_stub() {
    local bin="$1/node_modules/@fission-ai/openspec/bin"
    mkdir -p "$bin"
    cat > "$bin/openspec.js" <<'EOF'
const fs = require('fs'), path = require('path')
const [cmd, name] = process.argv.slice(2)
if (process.env.OPENSPEC_TELEMETRY !== '0') { console.error('telemetry on'); process.exit(9) }
const walk = d => fs.existsSync(d) ? fs.readdirSync(d, { withFileTypes: true }).flatMap(e =>
  e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]) : []
if (cmd === 'validate') {
  const bad = walk('openspec').filter(f => !f.includes('/archive/') && fs.readFileSync(f, 'utf8').includes('INVALID'))
  if (bad.length) { console.error('invalid: ' + bad.join(' ')); process.exit(1) }
  process.exit(0)
}
if (cmd === 'archive') {
  const src = path.join('openspec/changes', name)
  if (!fs.existsSync(src)) { console.error('no change ' + name); process.exit(1) }
  for (const f of walk(path.join(src, 'specs'))) {
    const dest = path.join('openspec/specs', path.relative(path.join(src, 'specs'), f))
    fs.mkdirSync(path.dirname(dest), { recursive: true })
    fs.copyFileSync(f, dest)
  }
  const date = process.env.STUB_DATE || new Date().toISOString().slice(0, 10)
  fs.mkdirSync('openspec/changes/archive', { recursive: true })
  fs.renameSync(src, path.join('openspec/changes/archive', date + '-' + name))
  process.exit(0)
}
process.exit(0)
EOF
}

add_change() {
    local repo="$1" name="$2" text="${3:-ok}"
    mkdir -p "$repo/openspec/changes/$name/specs/$name"
    echo "# $name" > "$repo/openspec/changes/$name/proposal.md"
    echo "$text" > "$repo/openspec/changes/$name/specs/$name/spec.md"
}

# --- usage errors -----------------------------------------------------------
expect_exit 2 bash "$INIT" --bogus
expect_exit 2 bash "$INIT" --openspec-version 1.14
expect_exit 2 bash "$T/openspec.sh"
expect_exit 2 bash "$T/sdd-archive.sh"
expect_exit 2 bash "$T/sdd-archive.sh" verify --base HEAD
expect_exit 2 bash "$T/check-specs.sh" --bogus
pass "usage errors exit 2"

# --- sdd-init: fresh repo -----------------------------------------------------
r="$(fresh_repo)"
out="$(bash "$INIT" --repo "$r" --no-install)"
[ "$(printf '%s\n' "$out" | tail -n 1)" = "sdd-init: done" ] || { echo "$out"; fail "init did not finish cleanly"; }
for f in scripts/sdd/openspec.sh scripts/sdd/sdd-archive.sh scripts/sdd/check-specs.sh \
         scripts/sdd/setup-agent-skills.mjs .claude/sdd-workflow.md .github/workflows/sdd-checks.yml \
         .claude/sdd-version openspec/conventions.md docs/decisions/README.md CLAUDE.md package.json; do
    [ -f "$r/$f" ] || fail "init did not create $f"
done
[ -x "$r/scripts/sdd/openspec.sh" ] || fail "scripts are not executable"
grep -qxF '@.claude/sdd-workflow.md' "$r/CLAUDE.md" || fail "CLAUDE.md lacks the import"
grep -qxF '.claude/skills/openspec-*/' "$r/.gitignore" || fail ".gitignore lacks generated skills"
node -e '
  const p = require(process.argv[1] + "/package.json"), s = require(process.argv[1] + "/.claude/settings.json")
  if (p.devDependencies["@fission-ai/openspec"] !== "1.14.1") throw "pin"
  if (p.scripts.prepare !== "node scripts/sdd/setup-agent-skills.mjs") throw "prepare"
  if (s.env.OPENSPEC_TELEMETRY !== "0") throw "telemetry"
  if (s.enabledPlugins["sdd@tzander-skills"] !== true) throw "enabled"
  if (s.extraKnownMarketplaces["tzander-skills"].source.repo !== "TimZander/claude") throw "marketplace"
' "$r" || fail "package.json or settings.json content"
pass "init sets up a fresh repo"

# --- sdd-init: idempotent ---------------------------------------------------------
out="$(bash "$INIT" --repo "$r" --no-install)"
if printf '%s\n' "$out" | grep -Eq '^  (added|updated|set) '; then echo "$out"; fail "second run changed files"; fi
[ "$(grep -c 'sdd-workflow.md' "$r/CLAUDE.md")" = 1 ] || fail "import line duplicated"
pass "init is idempotent"

# --- sdd-init: keeps the repo's own values, restores owned files -------------------
r2="$(fresh_repo)"
echo '{"name":"x","scripts":{"prepare":"node other.mjs"},"devDependencies":{"@fission-ai/openspec":"1.14.0"}}' > "$r2/package.json"
printf '# Mine\n\nUse /opsx:propose.\n' > "$r2/CLAUDE.md"
mkdir -p "$r2/openspec" && echo mine > "$r2/openspec/conventions.md"
out="$(bash "$INIT" --repo "$r2" --no-install)"
[ "$(printf '%s\n' "$out" | tail -n 1)" = 'sdd-init: done, 3 warnings' ] || { echo "$out"; fail "expected 3 warnings"; }
grep -q '"node other.mjs"' "$r2/package.json" || fail "overwrote the repo's prepare script"
grep -q '"1.14.0"' "$r2/package.json" || fail "overwrote the repo's OpenSpec pin"
[ "$(cat "$r2/openspec/conventions.md")" = mine ] || fail "overwrote repo-owned conventions"
head -n 1 "$r2/CLAUDE.md" | grep -q '# Mine' || fail "rewrote CLAUDE.md"
echo tampered > "$r2/.claude/sdd-workflow.md"
out="$(bash "$INIT" --repo "$r2" --no-install)"
printf '%s\n' "$out" | grep -q 'updated .claude/sdd-workflow.md' || fail "owned file not restored"
pass "init keeps repo values and restores plugin files"

# --- installed scripts, against the stub CLI ------------------------------------------
expect_exit 3 bash "$r/scripts/sdd/openspec.sh" -C "$r" validate
install_stub "$r"
echo node_modules >> "$r/.gitignore"
mkdir -p "$r/openspec/specs/base" && echo ok > "$r/openspec/specs/base/spec.md"
git -C "$r" add -A && git -C "$r" commit -q -m init
OPENSPEC_TELEMETRY=1 bash "$r/scripts/sdd/openspec.sh" -C "$r" validate || fail "openspec.sh did not force telemetry off"
pass "openspec.sh runs the pinned CLI with telemetry off"

add_change "$r" b-second
add_change "$r" a-first
[ "$(bash "$r/scripts/sdd/sdd-archive.sh" active -C "$r" | tr '\n' ' ')" = "a-first b-second " ] || fail "active order"
pass "active lists changes in name order"

git -C "$r" add -A && git -C "$r" commit -q -m changes
out="$(bash "$r/scripts/sdd/check-specs.sh" -C "$r")" || { echo "$out"; fail "check-specs on valid changes"; }
printf '%s\n' "$out" | grep -qx 'archived-specs: success' || fail "archived-specs verdict"
add_change "$r" c-bad "INVALID"
git -C "$r" add -A && git -C "$r" commit -q -m bad
expect_exit 1 bash "$r/scripts/sdd/check-specs.sh" -C "$r"
grep -qx 'spec-checks: failure' "$TMP_ROOT/out" || fail "check-specs verdict line"
git -C "$r" rm -rq openspec/changes/c-bad && git -C "$r" commit -q -m drop
[ -z "$(git -C "$r" worktree list | sed 1d)" ] || fail "check-specs left a worktree behind"
pass "check-specs validates before and after archiving"

base="$(git -C "$r" rev-parse HEAD)"
git -C "$r" checkout -q -b archive
STUB_DATE=2026-01-02 bash "$r/scripts/sdd/sdd-archive.sh" run -C "$r" >/dev/null
[ -d "$r/openspec/changes/archive/2026-01-02-a-first" ] || fail "run did not archive"
git -C "$r" add -A && git -C "$r" commit -q -m archive
out="$(bash "$r/scripts/sdd/sdd-archive.sh" verify -C "$r" --base "$base" --result HEAD)" || { echo "$out"; fail "verify on a mechanical archive"; }
[ "$(printf '%s\n' "$out" | tail -n 1)" = "archive-mechanical: success" ] || fail "verify verdict"
printf '%s\n' "$out" | grep -q "compared base $base" || fail "verify base line"
pass "verify accepts a mechanical archive, whatever day it re-runs"

echo extra >> "$r/README.md"
echo edited >> "$r/openspec/specs/a-first/spec.md"
git -C "$r" add -A && git -C "$r" commit -q -m sneak
expect_exit 1 bash "$r/scripts/sdd/sdd-archive.sh" verify -C "$r" --base "$base" --result HEAD
grep -q 'changed outside openspec/: README.md' "$TMP_ROOT/out" || fail "outside change not reported"
git -C "$r" checkout -q HEAD~1 -- README.md && git -C "$r" commit -q -m unsneak
expect_exit 1 bash "$r/scripts/sdd/sdd-archive.sh" verify -C "$r" --base "$base" --result HEAD
grep -q 'does not reproduce' "$TMP_ROOT/out" || fail "hand edit not reported"
expect_exit 0 bash "$r/scripts/sdd/sdd-archive.sh" verify -C "$r" --base "$base" --result "$base"
grep -qx 'archive-mechanical: not-an-archive-pr' "$TMP_ROOT/out" || fail "not-an-archive-pr"
pass "verify rejects edits outside openspec/ and hand edits"

# --- verdict parsing ------------------------------------------------------------------
printf '2026 x - compared base abc1234def with result 99\n2026 x archive-mechanical: success\n' > "$TMP_ROOT/log1"
out="$(bash "$T/sdd-archive.sh" verdict "$TMP_ROOT/log1")"
[ "$out" = "$(printf 'verdict=success\nbase=abc1234def')" ] || fail "verdict parse: $out"
printf 'openspec/archive-mechanical: failure\n' > "$TMP_ROOT/log2"
out="$(bash "$T/sdd-archive.sh" verdict "$TMP_ROOT/log2")"
printf '%s\n' "$out" | grep -qx 'verdict=failure' || fail "prefixed verdict"
printf 'nothing here\n' > "$TMP_ROOT/log3"
expect_exit 1 bash "$T/sdd-archive.sh" verdict "$TMP_ROOT/log3"
pass "verdict reads both log spellings"

echo "all sdd tests passed"
