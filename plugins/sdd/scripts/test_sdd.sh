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
  console.log('archive-mechanical: success')  // a forgery attempt: must come out quoted
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
[ "$(printf '%s\n' "$out" | tail -n 1)" = "sdd-init: done, 1 warnings" ] || { echo "$out"; fail "init did not finish cleanly"; }
printf '%s\n' "$out" | grep -q 'warning: no package-lock.json' || fail "no warning about the missing lock file"
pass "init warns that CI needs a lock file"
echo '{}' > "$r/package-lock.json"
for f in scripts/sdd/openspec.sh scripts/sdd/sdd-archive.sh scripts/sdd/check-specs.sh \
         scripts/sdd/session-start.sh scripts/sdd/setup-agent-skills.mjs .claude/sdd-workflow.md .github/workflows/sdd-checks.yml \
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
  const cmds = JSON.stringify(s.hooks.SessionStart)
  if (!cmds.includes("$CLAUDE_PROJECT_DIR/scripts/sdd/session-start.sh")) throw "session hook"
' "$r" || fail "package.json or settings.json content"
pass "init sets up a fresh repo"

# --- sdd-init: idempotent ---------------------------------------------------------
out="$(bash "$INIT" --repo "$r" --no-install)"
if printf '%s\n' "$out" | grep -Eq '^  (added|updated|set) '; then echo "$out"; fail "second run changed files"; fi
[ "$(grep -c 'sdd-workflow.md' "$r/CLAUDE.md")" = 1 ] || fail "import line duplicated"
[ "$(grep -o 'session-start.sh' "$r/.claude/settings.json" | wc -l | tr -d ' ')" = 1 ] || fail "session hook duplicated"
pass "init is idempotent"

# --- sdd-init: keeps the repo's own values, restores owned files -------------------
r2="$(fresh_repo)"
echo '{"name":"x","scripts":{"prepare":"node other.mjs"},"devDependencies":{"@fission-ai/openspec":"1.14.0"}}' > "$r2/package.json"
printf '# Mine\n\nUse /opsx:propose.\n' > "$r2/CLAUDE.md"
mkdir -p "$r2/openspec" && echo mine > "$r2/openspec/conventions.md"
mkdir -p "$r2/.claude" && echo '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}' > "$r2/.claude/settings.json"
out="$(bash "$INIT" --repo "$r2" --no-install)"
[ "$(printf '%s\n' "$out" | tail -n 1)" = 'sdd-init: done, 4 warnings' ] || { echo "$out"; fail "expected 4 warnings"; }
grep -q '"node other.mjs"' "$r2/package.json" || fail "overwrote the repo's prepare script"
grep -q '"1.14.0"' "$r2/package.json" || fail "overwrote the repo's OpenSpec pin"
[ "$(cat "$r2/openspec/conventions.md")" = mine ] || fail "overwrote repo-owned conventions"
head -n 1 "$r2/CLAUDE.md" | grep -q '# Mine' || fail "rewrote CLAUDE.md"
grep -q '"echo mine"' "$r2/.claude/settings.json" || fail "dropped the repo's own SessionStart hook"
grep -q 'session-start.sh' "$r2/.claude/settings.json" || fail "sdd hook not added next to the repo's own"
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
OPENSPEC_TELEMETRY=1 bash "$r/scripts/sdd/openspec.sh" -C "$r" validate >/dev/null || fail "openspec.sh did not force telemetry off"
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

# Fix 1: a revision that tracks node_modules/ never supplies the CLI.
git -C "$r" checkout -q -b evil
mkdir -p "$TMP_ROOT/evil/@fission-ai/openspec/bin"
echo 'console.log("PWNED")' > "$TMP_ROOT/evil/@fission-ai/openspec/bin/openspec.js"
blob="$(git -C "$r" hash-object -w "$TMP_ROOT/evil/@fission-ai/openspec/bin/openspec.js")"
git -C "$r" update-index --add --cacheinfo "100644,$blob,node_modules/@fission-ai/openspec/bin/openspec.js"
git -C "$r" commit -q -m evil
git -C "$r" rm -q --cached -r node_modules && git -C "$r" checkout -q main
expect_exit 1 bash "$r/scripts/sdd/check-specs.sh" -C "$r" --rev evil
grep -q 'tracks node_modules/' "$TMP_ROOT/out" || fail "tracked node_modules not refused"
if grep -q PWNED "$TMP_ROOT/out"; then fail "ran the revision's own CLI"; fi
pass "check-specs refuses a revision that tracks node_modules/"

# Fix 2: the CLI's output is quoted, so it can't print a verdict line.
out="$(bash "$r/scripts/sdd/check-specs.sh" -C "$r")" || { echo "$out"; fail "check-specs on main"; }
if printf '%s\n' "$out" | grep -qx 'archive-mechanical: success'; then fail "CLI output reached column 0"; fi
printf '%s\n' "$out" | grep -qx '  | archive-mechanical: success' || fail "CLI output not quoted"
pass "check-specs quotes the CLI's output"

# Fix 9: a change name that could pass as an option never reaches the CLI.
git -C "$r" checkout -q -b badname
add_change "$r" "--help"
git -C "$r" add -A && git -C "$r" commit -q -m badname
expect_exit 1 bash "$r/scripts/sdd/check-specs.sh" -C "$r"
grep -q 'not a valid change name' "$TMP_ROOT/out" || fail "invalid change name not reported"
expect_exit 1 bash "$r/scripts/sdd/sdd-archive.sh" active -C "$r"
git -C "$r" checkout -q main && git -C "$r" branch -qD badname
pass "invalid change names are refused"

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

# Fix 2: verify ends with a verdict on every exit path.
rnc="$(fresh_repo)"
mkdir -p "$rnc/scripts" && cp -R "$T" "$rnc/scripts/sdd"
git -C "$rnc" add -A && git -C "$rnc" commit -q -m b
add_change "$rnc" x && (cd "$rnc" && git add -A && git commit -q -m c)
git -C "$rnc" checkout -q -b arc
mkdir -p "$rnc/openspec/changes/archive" && git -C "$rnc" mv openspec/changes/x openspec/changes/archive/2026-01-01-x
git -C "$rnc" commit -q -m arc
expect_exit 3 bash "$rnc/scripts/sdd/sdd-archive.sh" verify -C "$rnc" --base main --result arc
[ "$(tail -n 1 "$TMP_ROOT/out")" = "archive-mechanical: failure" ] || fail "internal error without a verdict line"
pass "verify prints a failure verdict when it can't run"

# Fix 5: the right archive folder is renamed when names overlap.
r5="$(fresh_repo)"
mkdir -p "$r5/scripts" && cp -R "$T" "$r5/scripts/sdd" && install_stub "$r5" && echo node_modules > "$r5/.gitignore"
add_change "$r5" foo
mkdir -p "$r5/openspec/changes/archive/2025-01-01-foo" && echo old > "$r5/openspec/changes/archive/2025-01-01-foo/proposal.md"
add_change "$r5" bar-foo
git -C "$r5" add -A && git -C "$r5" commit -q -m base
base5="$(git -C "$r5" rev-parse HEAD)"
STUB_DATE=2026-02-03 bash "$r5/scripts/sdd/sdd-archive.sh" run -C "$r5" >/dev/null
git -C "$r5" add -A && git -C "$r5" commit -q -m archive
out="$(STUB_DATE=2026-09-09 bash "$r5/scripts/sdd/sdd-archive.sh" verify -C "$r5" --base "$base5" --result HEAD)" \
    || { echo "$out"; fail "verify with overlapping names"; }
pass "verify renames the folder each archive added, not a look-alike"

# --- session-start.sh: npm ci only when stale, status lines, never fails ---------------
r6="$(fresh_repo)"
bash "$INIT" --repo "$r6" --no-install >/dev/null
echo '{}' > "$r6/package-lock.json"
nfake="$TMP_ROOT/npmbin"
mkdir -p "$nfake"
cat > "$nfake/npm" <<'EOF2'
#!/bin/bash
echo "npm $*" >> "$NPM_LOG"
[ -z "${NPM_FAILS:-}" ] || exit 1
mkdir -p node_modules && touch node_modules/.package-lock.json
EOF2
chmod +x "$nfake/npm"
export NPM_LOG="$TMP_ROOT/npm.log"
ss() { PATH="$nfake:$PATH" bash "$r6/scripts/sdd/session-start.sh" "$r6"; }

: > "$NPM_LOG"
out="$(NPM_FAILS=1 ss)" || fail "session-start exited non-zero when npm failed"
printf '%s\n' "$out" | grep -q 'warning: `npm ci` failed' || { echo "$out"; fail "npm failure not reported"; }
out="$(ss)"
grep -q '^npm ci' "$NPM_LOG" || fail "session-start did not run npm ci on a fresh repo"
printf '%s\n' "$out" | grep -q 'installed the pinned OpenSpec CLI' || { echo "$out"; fail "install not reported"; }
: > "$NPM_LOG"
out="$(ss)"
[ ! -s "$NPM_LOG" ] || fail "session-start ran npm ci with node_modules current"
sleep 1; touch "$r6/package-lock.json"
out="$(ss)"
grep -q '^npm ci' "$NPM_LOG" || fail "session-start did not rerun npm ci after the lock file changed"
pass "session-start runs npm ci only when node_modules is stale, and never fails"

add_change "$r6" pending-one
printf '\nADR detail: learning\n' >> "$r6/CLAUDE.md"
out="$(ss)"
printf '%s\n' "$out" | grep -q 'active change(s) on this branch: pending-one' || { echo "$out"; fail "active change not reported"; }
printf '%s\n' "$out" | grep -q 'learning mode is on' || { echo "$out"; fail "learning mode not reported"; }
rm "$r6/.claude/sdd-workflow.md"
out="$(ss)"
printf '%s\n' "$out" | grep -q "isn't set up for spec-driven development; ask the owner" || { echo "$out"; fail "unset-up repo not reported"; }
pass "session-start reports active changes, learning mode, and a repo without sdd"

# --- verdict parsing ------------------------------------------------------------------
printf -- '- compared base abc1234def with result 0099aa\narchive-mechanical: success\n' > "$TMP_ROOT/log1"
out="$(bash "$T/sdd-archive.sh" verdict "$TMP_ROOT/log1")"
[ "$out" = "$(printf 'verdict=success\nbase=abc1234def')" ] || fail "verdict parse: $out"
printf 'openspec/archive-mechanical: failure\n' > "$TMP_ROOT/log2"
out="$(bash "$T/sdd-archive.sh" verdict "$TMP_ROOT/log2")"
printf '%s\n' "$out" | grep -qx 'verdict=failure' || fail "prefixed verdict"
printf 'nothing here\n' > "$TMP_ROOT/log3"
expect_exit 1 bash "$T/sdd-archive.sh" verdict "$TMP_ROOT/log3"
pass "verdict reads both log spellings"

# Fix 2: only whole lines count, and success needs the compared-base line before it.
printf '2026-10-13T10:00:00.1234567Z - compared base abc1234 with result def5678\n2026-10-13T10:00:01.0000000Z archive-mechanical: success\n' > "$TMP_ROOT/log4"
out="$(bash "$T/sdd-archive.sh" verdict "$TMP_ROOT/log4")"
[ "$out" = "$(printf 'verdict=success\nbase=abc1234')" ] || fail "timestamped log: $out"
printf 'checks\tArchive PR is mechanical\t2026-10-13T10:00:00.1Z - compared base abc1234 with result def5678\nchecks\tArchive PR is mechanical\t2026-10-13T10:00:01.1Z archive-mechanical: success\n' > "$TMP_ROOT/log5"
out="$(bash "$T/sdd-archive.sh" verdict "$TMP_ROOT/log5")"
[ "$out" = "$(printf 'verdict=success\nbase=abc1234')" ] || fail "gh run view log: $out"
printf '  | archive-mechanical: success\nx ✓ spec/archive-mechanical: success\nsdd-archive: died\n' > "$TMP_ROOT/log6"
expect_exit 1 bash "$T/sdd-archive.sh" verdict "$TMP_ROOT/log6"
grep -qx 'verdict=none' "$TMP_ROOT/out" || fail "a quoted or mid-line verdict counted"
printf 'spec-checks: success\narchive-mechanical: success\n' > "$TMP_ROOT/log7"
expect_exit 1 bash "$T/sdd-archive.sh" verdict "$TMP_ROOT/log7"
pass "verdict ignores quoted lines and success without its compared-base line"

# --- cloud-setup.sh: sdd only, always exits 0, updates an existing marketplace ---------
CS="$SCRIPT_DIR/../cloud-setup.sh"
fake="$TMP_ROOT/fakebin"
mkdir -p "$fake"
cat > "$fake/claude" <<'EOF2'
#!/bin/bash
echo "$*" >> "$FAKE_LOG"
case "$*" in
    "plugin marketplace add "*) [ -z "${FAKE_MARKETPLACE_EXISTS:-}" ] || exit 1 ;;
    "plugin install "*) [ -z "${FAKE_INSTALL_FAILS:-}" ] || exit 1 ;;
esac
exit 0
EOF2
printf '#!/bin/bash\nexit 0\n' > "$fake/apt-get"
chmod +x "$fake/claude" "$fake/apt-get"
export FAKE_LOG="$TMP_ROOT/fake.log"
cs_run() {
    : > "$FAKE_LOG"
    cs_status=0
    cs_out="$(PATH="$fake:$PATH" CLOUD_SETUP_HOME="$TMP_ROOT/cshome" bash "$CS" 2>&1)" || cs_status=$?
}

cs_run
[ "$cs_status" -eq 0 ] || { echo "$cs_out"; fail "cloud-setup exited $cs_status"; }
grep -qx 'plugin marketplace add TimZander/claude' "$FAKE_LOG" || { cat "$FAKE_LOG"; fail "cloud-setup did not add the marketplace"; }
grep -qx 'plugin install sdd@tzander-skills' "$FAKE_LOG" || fail "cloud-setup did not install sdd"
[ "$(grep -c '^plugin install ' "$FAKE_LOG")" = 1 ] || fail "cloud-setup installed more than sdd"
grep -q '=== sdd setup finished' "$TMP_ROOT/cshome/setup-script.log" || fail "cloud-setup wrote no log"
pass "cloud-setup installs sdd and nothing else, and logs it"
md="$TMP_ROOT/cshome/.claude/CLAUDE.md"
[ -f "$md" ] || fail "cloud-setup wrote no ~/.claude/CLAUDE.md"
grep -q 'sdd-workflow.md' "$md" || fail "CLAUDE.md does not point at the sdd workflow"
grep -q 'Never run `/sdd:init` unasked' "$md" || fail "CLAUDE.md does not say to ask before /sdd:init"
grep -q 'recording decisions as ADRs' "$md" || fail "CLAUDE.md does not point at the ADR rules"
pass "cloud-setup writes a CLAUDE.md that points at the workflow and asks before /sdd:init"

FAKE_MARKETPLACE_EXISTS=1 cs_run
grep -qx 'plugin marketplace update tzander-skills' "$FAKE_LOG" || { cat "$FAKE_LOG"; fail "cloud-setup did not update an existing marketplace"; }
pass "cloud-setup updates a marketplace that is already there"

FAKE_INSTALL_FAILS=1 cs_run
[ "$cs_status" -eq 0 ] || fail "cloud-setup exited $cs_status when the install failed"
printf '%s\n' "$cs_out" | grep -q 'WARNING: the sdd plugin did not install' || fail "failed install not reported"
pass "cloud-setup reports a failed install and still exits 0"

echo "all sdd tests passed"
