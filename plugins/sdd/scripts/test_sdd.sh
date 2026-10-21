#!/usr/bin/env bash
# Smoke test for the sdd plugin's scripts: the installer (sdd-init.sh) and the
# scripts it installs into a repo (template/scripts/sdd/). Uses real git repos
# and a stub OpenSpec CLI, so it runs offline: the stub archives a change by
# moving its folder to archive/<date>-<name> and applying its delta specs to
# the main specs, and fails `validate` when a spec contains the word INVALID.
#
#   bash plugins/sdd/scripts/test_sdd.sh
#   SDD_TEST_OPENSPEC=<dir> bash plugins/sdd/scripts/test_sdd.sh   # also against a real CLI

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
    local pkg="$1/node_modules/@fission-ai/openspec"
    mkdir -p "$pkg/bin" "$pkg/dist/core/parsers" "$pkg/dist/utils"
    echo '{"type":"module"}' > "$pkg/dist/package.json"
    # Just enough of OpenSpec's parsers: requirement blocks, delta sections, task lines.
    cat > "$pkg/dist/core/parsers/requirement-blocks.js" <<'EOF'
const HEADER = /^###\s+Requirement:\s*(.+?)\s*$/
function blocksOf(lines) {
  const out = []
  let cur = null
  for (const line of lines) {
    const m = HEADER.exec(line)
    if (m) { cur = { name: m[1], lines: [line] }; out.push(cur) } else if (cur) { cur.lines.push(line) }
  }
  return out.map(b => ({ name: b.name, raw: b.lines.join('\n').replace(/\s+$/, '') }))
}
function sections(content) {
  const out = {}
  let cur = null
  for (const line of content.replace(/\r\n?/g, '\n').split('\n')) {
    const m = /^##\s+(.+?)\s*$/.exec(line)
    if (m) { cur = m[1].toLowerCase(); out[cur] = [] } else if (cur) { out[cur].push(line) }
  }
  return out
}
export function extractRequirementsSection(content) {
  return { bodyBlocks: blocksOf(sections(content).requirements ?? []) }
}
export function parseDeltaSpec(content) {
  const s = sections(content)
  const renamed = []
  let from = null
  for (const line of s['renamed requirements'] ?? []) {
    const m = /^-\s*(FROM|TO):\s*`?###\s+Requirement:\s*(.+?)`?\s*$/.exec(line)
    if (m && m[1] === 'FROM') { from = m[2] } else if (m && from !== null) { renamed.push({ from, to: m[2] }); from = null }
  }
  return {
    added: blocksOf(s['added requirements'] ?? []),
    modified: blocksOf(s['modified requirements'] ?? []),
    removed: blocksOf(s['removed requirements'] ?? []).map(x => x.name),
    renamed,
  }
}
EOF
    cat > "$pkg/dist/utils/task-progress.js" <<'EOF'
export function parseTaskLines(content) {
  return content.split('\n').map(l => /^\s*(?:[-*+]|\d+\.)\s+\[([ xX])\]\s*(.*)$/.exec(l)).filter(Boolean)
    .map(m => ({ done: m[1] !== ' ', description: m[2] }))
}
EOF
    # The CLI: `validate` fails on the word INVALID; `archive` applies delta sections to the
    # main spec (or, for a delta without them, copies it over), then moves the change to
    # archive/<date>-<name>; `init` records its arguments.
    cat > "$pkg/bin/openspec.js" <<'EOF'
const fs = require('fs'), path = require('path')
const [cmd, name] = process.argv.slice(2)
if (process.env.OPENSPEC_TELEMETRY !== '0') { console.error('telemetry on'); process.exit(9) }
const walk = d => fs.existsSync(d) ? fs.readdirSync(d, { withFileTypes: true }).flatMap(e =>
  e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]) : []
async function main() {
  if (cmd === 'validate') {
    console.log('archive-mechanical: success')  // a forgery attempt: must come out quoted
    const bad = walk('openspec').filter(f => !f.includes('/archive/') && fs.readFileSync(f, 'utf8').includes('INVALID'))
    if (bad.length) { console.error('invalid: ' + bad.join(' ')); process.exit(1) }
    return
  }
  if (cmd === 'init') {
    if (process.env.STUB_INIT_LOG) fs.appendFileSync(process.env.STUB_INIT_LOG, process.argv.slice(2).join(' ') + '\n')
    return
  }
  if (cmd === 'archive') {
    const p = await import(path.join(__dirname, '../dist/core/parsers/requirement-blocks.js'))
    const src = path.join('openspec/changes', name)
    if (!fs.existsSync(src)) { console.error('no change ' + name); process.exit(1) }
    for (const f of walk(path.join(src, 'specs'))) {
      const dest = path.join('openspec/specs', path.relative(path.join(src, 'specs'), f))
      fs.mkdirSync(path.dirname(dest), { recursive: true })
      const delta = fs.readFileSync(f, 'utf8')
      if (!/^## (ADDED|MODIFIED|REMOVED|RENAMED) Requirements/m.test(delta)) { fs.copyFileSync(f, dest); continue }
      const main = fs.existsSync(dest) ? fs.readFileSync(dest, 'utf8') : '# Spec\n\n## Purpose\nA capability created by the stub, long enough to pass.\n\n## Requirements\n'
      const head = main.slice(0, main.indexOf('## Requirements') + '## Requirements'.length)
      const blocks = new Map(p.extractRequirementsSection(main).bodyBlocks.map(b => [b.name, b.raw]))
      const plan = p.parseDeltaSpec(delta)
      for (const x of plan.renamed) { const b = blocks.get(x.from); blocks.delete(x.from); blocks.set(x.to, b.replace(x.from, x.to)) }
      for (const x of plan.modified) { if (!blocks.has(x.name)) { console.error('no requirement ' + x.name); process.exit(1) } blocks.set(x.name, x.raw) }
      for (const x of plan.removed) blocks.delete(x)
      for (const x of plan.added) blocks.set(x.name, x.raw)
      fs.writeFileSync(dest, head + '\n\n' + [...blocks.values()].join('\n\n') + '\n')
    }
    const date = process.env.STUB_DATE || new Date().toISOString().slice(0, 10)
    fs.mkdirSync('openspec/changes/archive', { recursive: true })
    fs.renameSync(src, path.join('openspec/changes/archive', date + '-' + name))
  }
}
main().catch(e => { console.error(e); process.exit(1) })
EOF
}

# A change whose delta is plain text (copied over the main spec when archived), with empty
# base pins.
add_change() {
    local repo="$1" name="$2" text="${3:-ok}"
    mkdir -p "$repo/openspec/changes/$name/specs/$name"
    echo "# $name" > "$repo/openspec/changes/$name/proposal.md"
    echo "$text" > "$repo/openspec/changes/$name/specs/$name/spec.md"
    printf '{\n  "version": 1,\n  "pins": {\n    "%s": {}\n  }\n}\n' "$name" > "$repo/openspec/changes/$name/base-pins.json"
}

# --- usage errors -----------------------------------------------------------
expect_exit 2 bash "$INIT" --bogus
expect_exit 2 bash "$INIT" --openspec-version 1.14
expect_exit 2 bash "$T/openspec.sh"
expect_exit 2 bash "$T/sdd-archive.sh"
expect_exit 2 bash "$T/sdd-archive.sh" verify --base HEAD
expect_exit 2 bash "$T/check-specs.sh" --bogus
expect_exit 2 node "$T/sdd-specs.mjs" bogus
expect_exit 2 node "$T/sdd-specs.mjs" pin
expect_exit 2 node "$T/sdd-config.mjs" nonsense
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
[ "$(printf '%s\n' "$out" | tail -n 1)" = 'sdd-init: done, 5 warnings' ] || { echo "$out"; fail "expected 5 warnings"; }
printf '%s\n' "$out" | grep -q 'from 1.14.1, `validate --strict` fails any requirement whose text is over 500 characters' \
    || { echo "$out"; fail "no warning about 1.14.1's requirement-length rule"; }
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
# Older than any install below: bash 3.2 compares -nt in whole seconds on macOS.
touch -t 202001010000 "$r6/package-lock.json"
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
# CI= : these tests run in CI, where setup-agent-skills.mjs skips on purpose.
ss() { CI= PATH="$nfake:$PATH" bash "$r6/scripts/sdd/session-start.sh" "$r6"; }

: > "$NPM_LOG"
out="$(NPM_FAILS=1 ss)" || fail "session-start exited non-zero when npm failed"
printf '%s\n' "$out" | grep -q 'warning: `npm ci --ignore-scripts` failed' || { echo "$out"; fail "npm failure not reported"; }
install_stub "$r6"
export STUB_INIT_LOG="$TMP_ROOT/init.log"
: > "$STUB_INIT_LOG"
out="$(ss)"
grep -q '^npm ci' "$NPM_LOG" || fail "session-start did not run npm ci on a fresh repo"
if grep '^npm ci' "$NPM_LOG" | grep -vq -- '--ignore-scripts'; then cat "$NPM_LOG"; fail "session-start ran npm ci with install scripts"; fi
printf '%s\n' "$out" | grep -q 'installed the pinned OpenSpec CLI' || { echo "$out"; fail "install not reported"; }
grep -qx 'init --tools claude --no-animation' "$STUB_INIT_LOG" || { cat "$STUB_INIT_LOG"; fail "session-start did not generate the agent skills"; }
: > "$NPM_LOG"
out="$(ss)"
[ ! -s "$NPM_LOG" ] || fail "session-start ran npm ci with node_modules current"
sleep 1; touch "$r6/package-lock.json"
out="$(ss)"
grep -q '^npm ci' "$NPM_LOG" || fail "session-start did not rerun npm ci after the lock file changed"
pass "session-start runs npm ci --ignore-scripts only when node_modules is stale, then generates skills, and never fails"

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

# --- base pins, open tasks, requirements through a change, main-spec diff -----------------
rp="$(fresh_repo)"
bash "$INIT" --repo "$rp" --no-install >/dev/null
echo '{}' > "$rp/package-lock.json"
install_stub "$rp"
mkdir -p "$rp/openspec/specs/nav"
cat > "$rp/openspec/specs/nav/spec.md" <<'EOF'
# nav

## Purpose
How a visitor moves between the pages of the site.

## Requirements

### Requirement: NAV-1 Menu
The site SHALL show a menu.

#### Scenario: Menu
- **WHEN** a page loads
- **THEN** the menu shows

### Requirement: NAV-2 Footer
The site SHALL show a footer.
EOF
git -C "$rp" add -A && git -C "$rp" commit -q -m specs
SPECS="$rp/scripts/sdd/sdd-specs.mjs"
CHECK="$rp/scripts/sdd/check-specs.sh"
ARC="$rp/scripts/sdd/sdd-archive.sh"

# A change modifying NAV-1 (and adding NAV-9) with the text given.
delta_change() {
    local repo="$1" name="$2" text="$3"
    mkdir -p "$repo/openspec/changes/$name/specs/nav"
    echo "# $name" > "$repo/openspec/changes/$name/proposal.md"
    printf '## MODIFIED Requirements\n\n### Requirement: NAV-1 Menu\nThe site SHALL show %s.\n\n## ADDED Requirements\n\n### Requirement: NAV-9 %s\nThe site SHALL do %s.\n' \
        "$text" "$name" "$name" > "$repo/openspec/changes/$name/specs/nav/spec.md"
}

delta_change "$rp" a-menu "a top menu"
head_before="$(git -C "$rp" rev-parse HEAD)"
expect_exit 1 bash "$CHECK" -C "$rp" --worktree
grep -q '^- a-menu: no base-pins.json; run `npm run spec:pin -- a-menu`' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "missing pins not reported"; }
grep -qx 'base-pins: failure' "$TMP_ROOT/out" || fail "base-pins verdict"
grep -qx 'archived-specs: success' "$TMP_ROOT/out" || fail "--worktree did not see the uncommitted change"
[ "$(git -C "$rp" rev-parse HEAD)" = "$head_before" ] || fail "--worktree moved HEAD"
[ -n "$(git -C "$rp" status --porcelain openspec/changes)" ] || fail "--worktree touched the index"
[ -z "$(git -C "$rp" diff --cached --name-only)" ] || fail "--worktree staged files"
pass "check-specs --worktree checks uncommitted files and reports missing pins"

(cd "$rp" && node scripts/sdd/sdd-specs.mjs pin a-menu) >/dev/null || fail "pin failed"
node -e '
  const p = require(process.argv[1]).pins.nav
  if (!/^[0-9a-f]{64}$/.test(p["NAV-1 Menu"]) || p["NAV-9 a-menu"] !== null || Object.keys(p).length !== 2) throw JSON.stringify(p)
' "$rp/openspec/changes/a-menu/base-pins.json" || fail "pin format"
# The pin is the SHA-256 of the normalised block, as timzander.com's spec:pin writes it.
want="$(printf '### Requirement: NAV-1 Menu\nThe site SHALL show a menu.\n\n#### Scenario: Menu\n- **WHEN** a page loads\n- **THEN** the menu shows' | shasum -a 256 | cut -d' ' -f1)"
grep -q "\"NAV-1 Menu\": \"$want\"" "$rp/openspec/changes/a-menu/base-pins.json" || fail "pin is not the hash of the normalised block"
bash "$CHECK" -C "$rp" --worktree >"$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "check-specs after pinning"; }
mkdir -p "$rp/openspec/changes/z-bad/specs/nav"
printf '## MODIFIED Requirements\n\n### Requirement: NAV-404 Gone\nThe site SHALL x.\n' > "$rp/openspec/changes/z-bad/specs/nav/spec.md"
expect_exit 1 node "$SPECS" pin -C "$rp" z-bad
grep -q 'nav / NAV-404 Gone' "$TMP_ROOT/out" || fail "pin did not name the missing requirement"
[ ! -f "$rp/openspec/changes/z-bad/base-pins.json" ] || fail "pin wrote a file for a missing requirement"
printf '{"version":1,"pins":{"nav":{"NAV-404 Gone":"%s"}}}' "$want" > "$rp/openspec/changes/z-bad/base-pins.json"
expect_exit 1 bash "$CHECK" -C "$rp" --worktree
grep -q '`openspec archive z-bad` failed' "$TMP_ROOT/out" || fail "archive failure not reported"
bash "$CHECK" -C "$rp" --worktree --no-archive >"$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "--no-archive failed on a change that doesn't archive"; }
grep -qx 'archived-specs: skipped' "$TMP_ROOT/out" || fail "--no-archive verdict"
rm -rf "$rp/openspec/changes/z-bad"
expect_exit 2 bash "$CHECK" -C "$rp" --worktree --rev HEAD
pass "pin writes complete pins, refuses a missing requirement; --no-archive skips the archive"

# A change PR: requirements-through-change and the main-spec diff.
git -C "$rp" checkout -q -b change-a
git -C "$rp" add -A && git -C "$rp" commit -q -m change-a
out="$(node "$SPECS" requirements -C "$rp" --base main --result HEAD)" || { echo "$out"; fail "requirements on a clean change PR"; }
[ "$(printf '%s\n' "$out" | tail -n 1)" = 'requirements-through-change: success' ] || fail "requirements verdict"
out="$(node "$SPECS" spec-diff -C "$rp" --base main --result HEAD --out "$TMP_ROOT/diff.md")" || { echo "$out"; fail "spec-diff"; }
[ "$(printf '%s\n' "$out" | tail -n 1)" = 'main-spec-diff: success' ] || fail "spec-diff verdict"
head -n 1 "$TMP_ROOT/diff.md" | grep -qxF '<!-- sdd-main-spec-diff -->' || fail "comment marker"
grep -qF -- '- **From this PR:** `a-menu`' "$TMP_ROOT/diff.md" || fail "comment lists the change"
grep -qF -- '+The site SHALL show a top menu.' "$TMP_ROOT/diff.md" || { cat "$TMP_ROOT/diff.md"; fail "comment diff"; }
grep -qF -- '+++ b/openspec/specs/nav/spec.md' "$TMP_ROOT/diff.md" || fail "diff paths not labelled openspec/specs"
pass "a change PR passes requirements-through-change and gets a main-spec diff"

git -C "$rp" checkout -q -b direct
sed -i.bak 's/show a footer/show a big footer/' "$rp/openspec/specs/nav/spec.md" && rm "$rp/openspec/specs/nav/spec.md.bak"
git -C "$rp" commit -q -am direct
expect_exit 1 node "$SPECS" requirements -C "$rp" --base main --result HEAD
grep -qx -- '- nav / NAV-2 Footer: edited without a change' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "direct edit not reported"; }
git -C "$rp" checkout -q change-a && git -C "$rp" branch -qD direct
pass "requirements-through-change fails a direct edit of a main spec"

# Main moves on: change-a merges and is archived; b-menu was pinned before that.
git -C "$rp" checkout -q main && git -C "$rp" merge -q --no-ff -m merge-a change-a
git -C "$rp" checkout -q -b change-b main~1
delta_change "$rp" b-menu "a side menu"
(cd "$rp" && node scripts/sdd/sdd-specs.mjs pin b-menu) >/dev/null
git -C "$rp" add -A && git -C "$rp" commit -q -m change-b
git -C "$rp" checkout -q main && git -C "$rp" merge -q --no-ff -m merge-b change-b
base="$(git -C "$rp" rev-parse HEAD)"
out="$(node "$SPECS" spec-diff -C "$rp" --base main~1 --result HEAD --out "$TMP_ROOT/diff2.md")"
grep -qF -- '- **Already on the base:** `a-menu`' "$TMP_ROOT/diff2.md" || { cat "$TMP_ROOT/diff2.md"; fail "base change not listed"; }
grep -qF 'They touch the same requirements as this PR: `nav / NAV-1 Menu`' "$TMP_ROOT/diff2.md" || fail "shared requirement not named"
git -C "$rp" checkout -q -b archive-ab
STUB_DATE=2026-03-04 bash "$ARC" run -C "$rp" >/dev/null
git -C "$rp" add -A && git -C "$rp" commit -q -m archive
expect_exit 1 bash "$ARC" verify -C "$rp" --base "$base" --result HEAD
grep -qx -- '- b-menu: nav / NAV-1 Menu changed since the delta was written; merge the newer text into the delta, re-pin, and have the archive reviewed' "$TMP_ROOT/out" \
    || { cat "$TMP_ROOT/out"; fail "stale pin not reported by verify"; }
[ "$(tail -n 1 "$TMP_ROOT/out")" = 'archive-mechanical: failure' ] || fail "stale pin verdict"
out="$(node "$SPECS" requirements -C "$rp" --base "$base" --result HEAD)" || { echo "$out"; fail "requirements on an archive PR"; }
pass "verify fails an archive whose pins went stale earlier in the same PR"

# With pins off, the same archive is mechanical. The setting comes from the checkout the
# scripts run from.
node -e 'const f=process.argv[1],p=require(f);p.sdd={pins:false};require("fs").writeFileSync(f,JSON.stringify(p,null,2))' "$rp/package.json"
out="$(bash "$ARC" verify -C "$rp" --base "$base" --result HEAD)" || { echo "$out"; fail "verify with pins off"; }
git -C "$rp" checkout -q package.json
pass "pins can be turned off in package.json"

# Open tasks block a mechanical archive.
git -C "$rp" checkout -q main
git -C "$rp" checkout -q -b tasks
printf -- '- [x] 1.1 done\n1. [ ] 1.2 not yet\n' > "$rp/openspec/changes/a-menu/tasks.md"
git -C "$rp" add -A && git -C "$rp" commit -q -m tasks
tbase="$(git -C "$rp" rev-parse HEAD)"
STUB_DATE=2026-03-04 bash "$ARC" run -C "$rp" >/dev/null
git -C "$rp" add -A && git -C "$rp" commit -q -m archive
expect_exit 1 bash "$ARC" verify -C "$rp" --base "$tbase" --result HEAD
grep -qx -- '- a-menu: 1 unfinished task in tasks.md' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "open task not reported"; }
pass "verify fails an archive with an unfinished task"

# A change PR whose pins went stale on the base: c-menu is pinned on main, then a-menu's
# archive lands first.
git -C "$rp" checkout -q -b archive-a main
(cd "$rp" && OPENSPEC_TELEMETRY=0 STUB_DATE=2026-03-04 node node_modules/@fission-ai/openspec/bin/openspec.js archive a-menu --yes)
git -C "$rp" add -A && git -C "$rp" commit -q -m archive-a-only
newbase="$(git -C "$rp" rev-parse HEAD)"
git -C "$rp" checkout -q -b change-c main
delta_change "$rp" c-menu "a bottom menu"
(cd "$rp" && node scripts/sdd/sdd-specs.mjs pin c-menu) >/dev/null
git -C "$rp" add -A && git -C "$rp" commit -q -m change-c
git -C "$rp" checkout -q -b c-merged "$newbase" && git -C "$rp" merge -q --no-edit change-c
expect_exit 1 node "$SPECS" requirements -C "$rp" --base "$newbase" --result HEAD
grep -q '^- c-menu: nav / NAV-1 Menu changed since the delta was written; update the delta, then run `npm run spec:pin -- c-menu`' "$TMP_ROOT/out" \
    || { cat "$TMP_ROOT/out"; fail "stale pin on a change PR not reported"; }
pass "requirements-through-change reports a change PR's stale pins"

# Backticks in spec text lengthen the diff's fence.
git -C "$rp" checkout -q -b ticks "$newbase"
delta_change "$rp" d-ticks 'a ````quoted```` menu'
(cd "$rp" && node scripts/sdd/sdd-specs.mjs pin d-ticks) >/dev/null
git -C "$rp" add -A && git -C "$rp" commit -q -m ticks
node "$SPECS" spec-diff -C "$rp" --base "$newbase" --result HEAD --out "$TMP_ROOT/diff3.md" >/dev/null
grep -qx '`````diff' "$TMP_ROOT/diff3.md" || { cat "$TMP_ROOT/diff3.md"; fail "fence not lengthened"; }
out="$(node "$SPECS" spec-diff -C "$rp" --base "$head_before" --result "$head_before" --out "$TMP_ROOT/diff4.md")"
[ "$(printf '%s\n' "$out" | tail -n 1)" = 'main-spec-diff: no-active-change' ] || { echo "$out"; fail "no-active-change verdict"; }
pass "spec-diff lengthens fences and reports a PR without an active change"

# --- settings: change names, tools, invalid settings --------------------------------------
rn="$(fresh_repo)"
mkdir -p "$rn/scripts" && cp -R "$T" "$rn/scripts/sdd" && install_stub "$rn" && echo node_modules > "$rn/.gitignore"
add_change "$rn" Upper.Case
bash "$rn/scripts/sdd/sdd-archive.sh" active -C "$rn" >/dev/null || fail "default rule refused Upper.Case"
echo '{"sdd":{"changeNames":"lowercase"}}' > "$rn/package.json"
expect_exit 1 bash "$rn/scripts/sdd/sdd-archive.sh" active -C "$rn"
grep -q 'not a valid change name: Upper.Case' "$TMP_ROOT/out" || fail "lowercase rule not applied"
rm -rf "$rn/openspec/changes/Upper.Case" && add_change "$rn" 2026-01-01-dated
expect_exit 1 bash "$rn/scripts/sdd/sdd-archive.sh" active -C "$rn"
rm -rf "$rn/openspec/changes/2026-01-01-dated" && add_change "$rn" "two
lines"
echo '{}' > "$rn/package.json"
expect_exit 1 bash "$rn/scripts/sdd/sdd-archive.sh" active -C "$rn"
rm -rf "$rn/openspec/changes/two
lines"
echo '{"sdd":{"pinz":false}}' > "$rn/package.json"
expect_exit 3 node "$rn/scripts/sdd/sdd-config.mjs" pins
grep -q 'sdd.pinz is not an sdd setting' "$TMP_ROOT/out" || fail "unknown setting not reported"
expect_exit 3 bash "$rn/scripts/sdd/sdd-archive.sh" active -C "$rn"
echo '{"sdd":{"tools":["claude","opencode"]}}' > "$rn/package.json"
: > "$TMP_ROOT/init.log"
CI= STUB_INIT_LOG="$TMP_ROOT/init.log" node "$rn/scripts/sdd/setup-agent-skills.mjs" >/dev/null || fail "setup-agent-skills"
grep -qx 'init --tools claude,opencode --no-animation' "$TMP_ROOT/init.log" || { cat "$TMP_ROOT/init.log"; fail "tools not read from package.json"; }
pass "settings: a stricter change-name rule, a name with a line break, unknown keys, agent tools"

# --- other checks' verdicts, for archiveVerdicts -----------------------------------------
printf 'checks\tArchive PR\t2026-10-13T10:00:00.1Z openspec/archive-mechanical: failure\nchecks\tArchive PR\t2026-10-13T10:00:01.1Z openspec/archive-mechanical: success\n' > "$TMP_ROOT/log8"
out="$(bash "$T/sdd-archive.sh" verdict --line openspec/archive-mechanical "$TMP_ROOT/log8")"
[ "$out" = "$(printf 'verdict=success\nbase=unknown')" ] || fail "--line verdict: $out"
printf '  | openspec/archive-mechanical: success\nx openspec/archive-mechanical: success\n' > "$TMP_ROOT/log9"
expect_exit 1 bash "$T/sdd-archive.sh" verdict --line openspec/archive-mechanical "$TMP_ROOT/log9"
expect_exit 2 bash "$T/sdd-archive.sh" verdict --line 'bad name' "$TMP_ROOT/log9"
# A tab in quoted text never makes what follows it a whole line.
printf '2026-10-13T10:00:00.1Z - nav / x\tstep\topenspec/archive-mechanical: success\n2026-10-13T10:00:00.1Z - a\tb\t2026-10-13T10:00:00.1Z openspec/archive-mechanical: success\n' > "$TMP_ROOT/log10"
expect_exit 1 bash "$T/sdd-archive.sh" verdict --line openspec/archive-mechanical "$TMP_ROOT/log10"
[ "$(printf 'a\tb' | node -e 'import("'"$T"'/sdd-specs.mjs").then(m => process.stdout.write(m.clean(require("fs").readFileSync(0, "utf8"))))')" = 'a b' ] || fail "clean() kept a tab"
pass "verdict --line reads another check's whole verdict line only"

# --- sdd-github.mjs: statuses and the comment, as package.json asks -------------------------
cat > "$TMP_ROOT/report.mjs" <<'EOF'
const [mod, statuses, comment] = process.argv.slice(2)
const { report } = await import(mod)
const calls = []
const existing = [
  { id: 1, user: { login: 'someone' }, body: '<!-- sdd-main-spec-diff -->\nquoted by a person' },
  { id: 2, user: { login: 'github-actions[bot]' }, body: '<!-- sdd-main-spec-diff -->\nold' },
]
const fetch = async (url, init) => {
  calls.push(`${init.method} ${new URL(url).pathname}${init.body ? ' ' + init.body : ''}`)
  const body = init.method === 'GET' ? JSON.stringify(process.env.NO_COMMENTS ? [] : existing) : '{}'
  return { ok: !(process.env.REFUSE && init.method === 'POST'), status: process.env.REFUSE ? 403 : 200, text: async () => body }
}
const lines = []
await report({
  env: { GITHUB_TOKEN: 't', GITHUB_REPOSITORY: 'o/r', PR_NUMBER: '7', HEAD_SHA: 'abc', RUN_URL: 'https://run' },
  fetch, log: x => lines.push(x),
  config: { statuses: statuses === 'true', specDiffComment: true },
}, new Map([['spec-checks', 'success'], ['archive-mechanical', 'not-an-archive-pr'], ['main-spec-diff', process.env.DIFF ?? 'success'], ['requirements-through-change', '']]), comment)
console.log(calls.join('\n'))
console.log(lines.join('\n'))
EOF
echo body > "$TMP_ROOT/comment.md"
out="$(node "$TMP_ROOT/report.mjs" "$T/sdd-github.mjs" false "$TMP_ROOT/comment.md")"
printf '%s\n' "$out" | grep -q '^POST /repos/o/r/statuses' && fail "posted statuses with statuses off"
printf '%s\n' "$out" | grep -qx 'PATCH /repos/o/r/issues/comments/2 {"body":"body\\n"}' || { echo "$out"; fail "did not update its own comment"; }
printf '%s\n' "$out" | grep -q 'comments/1' && fail "edited a person's comment"
out="$(node "$TMP_ROOT/report.mjs" "$T/sdd-github.mjs" true "$TMP_ROOT/comment.md")"
printf '%s\n' "$out" | grep -q '"state":"success","context":"sdd/archive-mechanical","description":"Not an archive PR"' || { echo "$out"; fail "status for not-an-archive-pr"; }
printf '%s\n' "$out" | grep -q '"state":"error","context":"sdd/requirements-through-change"' || fail "a check that didn't run is not error"
out="$(NO_COMMENTS=1 DIFF=no-active-change node "$TMP_ROOT/report.mjs" "$T/sdd-github.mjs" false "$TMP_ROOT/comment.md")"
printf '%s\n' "$out" | grep -q '^POST' && { echo "$out"; fail "created a comment for a PR without an active change"; }
out="$(REFUSE=1 NO_COMMENTS=1 node "$TMP_ROOT/report.mjs" "$T/sdd-github.mjs" true "$TMP_ROOT/comment.md")" || fail "a refused post failed the reporter"
printf '%s\n' "$out" | grep -q 'could not post sdd/spec-checks (HTTP 403)' || { echo "$out"; fail "refusal not reported"; }
pass "sdd-github posts statuses only when asked, and edits only its own comment"

# --- sdd-checks.yml: the merge-commit fetch carries the token (private repositories) ------
WF="$SCRIPT_DIR/../template/.github/workflows/sdd-checks.yml"
[ "$(grep -c 'GITHUB_TOKEN: ${{ github.token }}' "$WF")" = 2 ] || fail "the token should reach exactly two steps"
awk '/- name: Fetch the PR.s merge commit as data/ { f = 1 } f && /^      - name:/ && !/Fetch/ { exit } f && r { sub(/^          /, ""); print } f && /run: \|/ { r = 1 }' "$WF" > "$TMP_ROOT/fetch.sh"
grep -q 'git fetch' "$TMP_ROOT/fetch.sh" || fail "could not extract the fetch step"
# An origin that, like a private repository, refuses a fetch without the token.
wo="$TMP_ROOT/wf-origin" && wc="$TMP_ROOT/wf-clone"
git init -q -b main "$wo" && git -C "$wo" -c user.email=t@e -c user.name=t commit -q --allow-empty -m base
git -C "$wo" checkout -q -b pr-head && git -C "$wo" -c user.email=t@e -c user.name=t commit -q --allow-empty -m head
git -C "$wo" checkout -q main && git -C "$wo" -c user.email=t@e -c user.name=t merge -q --no-ff --no-edit pr-head
git -C "$wo" update-ref refs/pull/5/merge HEAD
git clone -q "$wo" "$wc"
gfake="$TMP_ROOT/gitfake" && mkdir -p "$gfake"
real_git="$(command -v git)"
cat > "$gfake/git" <<EOF
#!/bin/bash
if [ "\$1" = fetch ]; then
    want="AUTHORIZATION: basic \$(printf 'x-access-token:%s' secret-token | base64 | tr -d '\n')"
    if [ "\${GIT_CONFIG_COUNT:-}" != 1 ] || [ "\${GIT_CONFIG_KEY_0:-}" != "http.https://github.com/.extraheader" ] || [ "\${GIT_CONFIG_VALUE_0:-}" != "\$want" ]; then
        echo "fatal: could not read Username for 'https://github.com': terminal prompts disabled" >&2
        exit 128
    fi
fi
exec "$real_git" "\$@"
EOF
printf '#!/bin/bash\nexit 0\n' > "$gfake/sleep"
chmod +x "$gfake/git" "$gfake/sleep"
head_sha="$(git -C "$wo" rev-parse pr-head)"
: > "$TMP_ROOT/gh-output"
(cd "$wc" && PATH="$gfake:$PATH" PR=5 HEAD_SHA="$head_sha" SERVER_URL=https://github.com GITHUB_TOKEN=secret-token \
    GITHUB_OUTPUT="$TMP_ROOT/gh-output" bash -e "$TMP_ROOT/fetch.sh") >"$TMP_ROOT/out" 2>&1 || { cat "$TMP_ROOT/out"; fail "fetch step failed with the token"; }
grep -qx "result=$(git -C "$wo" rev-parse refs/pull/5/merge)" "$TMP_ROOT/gh-output" || fail "fetch step output"
[ -z "$(git -C "$wc" config --get-regexp 'extraheader' || true)" ] || fail "the token was stored in .git/config"
fetch_wrong() {
    cd "$wc" && PATH="$gfake:$PATH" PR=5 HEAD_SHA="$head_sha" SERVER_URL=https://github.com GITHUB_TOKEN=wrong \
        GITHUB_OUTPUT="$TMP_ROOT/gh-output" bash -e "$TMP_ROOT/fetch.sh"
}
expect_exit 1 fetch_wrong
cd "$SCRIPT_DIR"
grep -q '^  | fatal: could not read Username' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "git's error not shown, quoted"; }
grep -qx 'archive-mechanical: failure' "$TMP_ROOT/out" || fail "no verdict when the fetch fails"
pass "the workflow fetches the merge commit with the token, and shows git's error when it can't"

# --- sdd-init: spec:pin, unpinned active changes -------------------------------------------
ri="$(fresh_repo)"
add_change "$ri" pinned
add_change "$ri" unpinned && rm "$ri/openspec/changes/unpinned/base-pins.json"
out="$(bash "$INIT" --repo "$ri" --no-install)"
printf '%s\n' "$out" | grep -q 'warning: active change unpinned has no base-pins.json' || { echo "$out"; fail "unpinned change not reported"; }
printf '%s\n' "$out" | grep -q 'active change pinned has' && fail "pinned change reported"
grep -q '"spec:pin": "node scripts/sdd/sdd-specs.mjs pin"' "$ri/package.json" || fail "spec:pin script"
pass "init adds spec:pin and reports active changes without pins"

# --- optional: the same pin and archive checks against the real OpenSpec CLI -----------------
# SDD_TEST_OPENSPEC=<dir whose node_modules holds @fission-ai/openspec> runs them; skipped
# otherwise, so the test stays offline.
if [ -n "${SDD_TEST_OPENSPEC:-}" ]; then
    rr="$(fresh_repo)"
    bash "$INIT" --repo "$rr" --no-install >/dev/null
    ln -s "$SDD_TEST_OPENSPEC/node_modules" "$rr/node_modules"
    mkdir -p "$rr/openspec/specs/nav"
    printf '# nav Specification\n\n## Purpose\nHow a visitor moves between the pages and sections of the site.\n\n## Requirements\n\n### Requirement: NAV-1 Menu\nThe site SHALL show a menu.\n\n#### Scenario: Menu\n- **WHEN** a page loads\n- **THEN** the menu shows\n' > "$rr/openspec/specs/nav/spec.md"
    for c in a-real b-real; do
        mkdir -p "$rr/openspec/changes/$c/specs/nav"
        printf '# %s\n\n## Why\nThe menu needs to move so that visitors can find it on small screens.\n\n## What Changes\n- The menu moves.\n' "$c" > "$rr/openspec/changes/$c/proposal.md"
        printf -- '- [x] 1.1 Move the menu\n' > "$rr/openspec/changes/$c/tasks.md"
        printf '## MODIFIED Requirements\n\n### Requirement: NAV-1 Menu\nThe site SHALL show a menu (%s).\n\n#### Scenario: Menu\n- **WHEN** a page loads\n- **THEN** the menu shows\n' "$c" > "$rr/openspec/changes/$c/specs/nav/spec.md"
        (cd "$rr" && node scripts/sdd/sdd-specs.mjs pin "$c") >/dev/null || fail "real: pin $c"
    done
    git -C "$rr" add -A && git -C "$rr" commit -q -m changes
    out="$(bash "$rr/scripts/sdd/check-specs.sh" -C "$rr")" || { echo "$out"; fail "real: check-specs"; }
    rbase="$(git -C "$rr" rev-parse HEAD)"
    git -C "$rr" checkout -q -b archive
    bash "$rr/scripts/sdd/sdd-archive.sh" run -C "$rr" >/dev/null 2>&1 || fail "real: archive run"
    git -C "$rr" add -A && git -C "$rr" commit -q -m archive
    expect_exit 1 bash "$rr/scripts/sdd/sdd-archive.sh" verify -C "$rr" --base "$rbase" --result HEAD
    grep -q '^- b-real: nav / NAV-1 Menu changed since the delta was written' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "real: stale pin"; }
    out="$(node "$rr/scripts/sdd/sdd-specs.mjs" requirements -C "$rr" --base "$rbase" --result HEAD)" || { echo "$out"; fail "real: requirements"; }
    pass "real OpenSpec CLI: pins, check-specs, and a stale pin at archive time"
fi

# --- sdd-optout.sh: adds the line once, creates CLAUDE.md, refuses an sdd repository --------
OPT="$SCRIPT_DIR/sdd-optout.sh"
optline="This repository doesn't use spec-driven development (sdd)."
expect_exit 2 bash "$OPT" --bogus
expect_exit 1 bash "$OPT" --repo "$TMP_ROOT"
o="$(fresh_repo)"
bash "$OPT" --repo "$o" | tail -n 1 | grep -qx 'sdd-optout: done' || fail "opt-out without a CLAUDE.md"
[ "$(cat "$o/CLAUDE.md")" = "$(printf '# CLAUDE.md\n\n%s' "$optline")" ] || { cat "$o/CLAUDE.md"; fail "opt-out created the wrong CLAUDE.md"; }
o2="$(fresh_repo)"
printf '# Mine\n\nNo trailing newline' > "$o2/CLAUDE.md"
bash "$OPT" --repo "$o2" >/dev/null
[ "$(cat "$o2/CLAUDE.md")" = "$(printf '# Mine\n\nNo trailing newline\n\n%s' "$optline")" ] || { cat "$o2/CLAUDE.md"; fail "opt-out mangled an existing CLAUDE.md"; }
before="$(cat "$o2/CLAUDE.md")"
bash "$OPT" --repo "$o2" | tail -n 1 | grep -qx 'sdd-optout: already opted out' || fail "second opt-out"
[ "$(cat "$o2/CLAUDE.md")" = "$before" ] || fail "second opt-out changed CLAUDE.md"
[ -z "$(git -C "$o2" log --oneline -1 -- CLAUDE.md)" ] || fail "opt-out committed"
o3="$(fresh_repo)"
mkdir -p "$o3/.claude" && echo x > "$o3/.claude/sdd-workflow.md"
expect_exit 1 bash "$OPT" --repo "$o3"
grep -q 'set up for sdd' "$TMP_ROOT/out" || fail "opt-out of an sdd repository not refused"
[ ! -e "$o3/CLAUDE.md" ] || fail "a refused opt-out wrote CLAUDE.md"
pass "sdd-optout adds the line once, creates CLAUDE.md, commits nothing, and refuses an sdd repository"

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
grep -qx 'plugin install handoff@tzander-skills' "$FAKE_LOG" || fail "cloud-setup did not install handoff"
[ "$(grep -c '^plugin install ' "$FAKE_LOG")" = 2 ] || fail "cloud-setup installed more than sdd and handoff"
grep -q '=== sdd setup finished' "$TMP_ROOT/cshome/setup-script.log" || fail "cloud-setup wrote no log"
pass "cloud-setup installs sdd and handoff and nothing else, and logs it"
md="$TMP_ROOT/cshome/.claude/CLAUDE.md"
[ -f "$md" ] || fail "cloud-setup wrote no ~/.claude/CLAUDE.md"
grep -q 'sdd-workflow.md' "$md" || fail "CLAUDE.md does not point at the sdd workflow"
grep -q 'Never run `/sdd:init` unasked' "$md" || fail "CLAUDE.md does not say to ask before /sdd:init"
grep -q "doesn't use spec-driven development" "$md" || fail "CLAUDE.md does not describe the opt-out"
grep -q 'Neither: ask once, at the first change' "$md" || fail "CLAUDE.md does not limit the ask to once"
grep -q '`/sdd:opt-out`' "$md" || fail "CLAUDE.md does not name /sdd:opt-out"
grep -q 'recording decisions as ADRs' "$md" || fail "CLAUDE.md does not point at the ADR rules"
grep -q '`/handoff`' "$md" || fail "CLAUDE.md does not mention /handoff"
pass "cloud-setup writes a CLAUDE.md that points at the workflow, honors an opt-out, and asks once before /sdd:init"

FAKE_MARKETPLACE_EXISTS=1 cs_run
grep -qx 'plugin marketplace update tzander-skills' "$FAKE_LOG" || { cat "$FAKE_LOG"; fail "cloud-setup did not update an existing marketplace"; }
pass "cloud-setup updates a marketplace that is already there"

FAKE_INSTALL_FAILS=1 cs_run
[ "$cs_status" -eq 0 ] || fail "cloud-setup exited $cs_status when the install failed"
printf '%s\n' "$cs_out" | grep -q 'WARNING: the sdd plugin did not install' || fail "failed install not reported"
grep -qx 'plugin install handoff@tzander-skills' "$FAKE_LOG" || fail "a failed sdd install stopped the handoff install"
pass "cloud-setup reports a failed install, still installs the rest, and exits 0"

echo "all sdd tests passed"
