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
    console.log('x ##vso[task.complete result=Succeeded]x ##VsO[task.setvariable variable=y]y')  // and broken
    const bad = walk('openspec').filter(f => !f.includes('/archive/') && fs.readFileSync(f, 'utf8').includes('INVALID'))
    if (bad.length) { console.error('invalid: ' + bad.join(' ')); process.exit(1) }
    return
  }
  if (cmd === 'init') {
    if (process.env.STUB_INIT_LOG) fs.appendFileSync(process.env.STUB_INIT_LOG, process.argv.slice(2).join(' ') + '\n')
    return
  }
  if (cmd === 'archive') {
    const p = await import(require('url').pathToFileURL(path.join(__dirname, '../dist/core/parsers/requirement-blocks.js')).href)
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
         scripts/sdd/sdd-github.mjs scripts/sdd/sdd-azure.mjs scripts/sdd/sdd-azure-pr.sh \
         .claude/sdd-version openspec/conventions.md docs/decisions/README.md CLAUDE.md package.json; do
    [ -f "$r/$f" ] || fail "init did not create $f"
done
# A repository with no remote is set up for GitHub, the default, and records no host.
printf '%s\n' "$out" | sed -n 1p | grep -q '(host: github, from the default)$' || fail "a repo with no remote isn't GitHub by default"
[ ! -e "$r/.azure-pipelines" ] || fail "a GitHub repo got the Azure Pipelines template"
grep -q '"sdd"' "$r/package.json" && fail "a GitHub repo got an sdd setting"
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

# --- sdd-init: removes an earlier opt-out ------------------------------------------
optline="$(cat "$SCRIPT_DIR/optout-line.txt")"
ro="$(fresh_repo)"
printf '# Mine\n\nKeep this.\n\n%s\n\nThe docs tree doesn'"'"'t use spec-driven development (sdd).\n\n%s\r\n' "$optline" "$optline" > "$ro/CLAUDE.md"
out="$(bash "$INIT" --repo "$ro" --no-install)" || { echo "$out"; fail "init on an opted-out repo"; }
printf '%s\n' "$out" | grep -q "removed the sdd opt-out from CLAUDE.md" || { echo "$out"; fail "init did not report removing the opt-out"; }
grep -qxF "$optline" "$ro/CLAUDE.md" && fail "init left the opt-out line"
[ "$(sed -n 1,6p "$ro/CLAUDE.md")" = "$(printf "# Mine\n\nKeep this.\n\nThe docs tree doesn't use spec-driven development (sdd).\n")" ] \
    || { cat -A "$ro/CLAUDE.md"; fail "init removed more than the exact opt-out line, or left a stray blank line"; }
[ "$(sed -n 7p "$ro/CLAUDE.md")" = "## Spec-driven workflow" ] || { cat -A "$ro/CLAUDE.md"; fail "init left a stray blank line where the opt-out ended the file"; }
grep -qxF '@.claude/sdd-workflow.md' "$ro/CLAUDE.md" || fail "init on an opted-out repo did not add the import"
# Round trip: what /sdd:opt-out writes, /sdd:init removes, through a symlinked CLAUDE.md.
rs="$(fresh_repo)"
printf '# Agents\n\nRules.\n' > "$rs/AGENTS.md" && ln -s AGENTS.md "$rs/CLAUDE.md"
git -C "$rs" add -A && git -C "$rs" commit -q -m agents
bash "$SCRIPT_DIR/sdd-optout.sh" --repo "$rs" >/dev/null
grep -qxF "$optline" "$rs/AGENTS.md" || fail "opt-out did not write through the symlink"
git -C "$rs" commit -q -am optout
bash "$INIT" --repo "$rs" --no-install >/dev/null
[ -L "$rs/CLAUDE.md" ] || fail "init replaced a symlinked CLAUDE.md with a file"
grep -qxF "$optline" "$rs/AGENTS.md" && fail "init left the opt-out in the symlink's target"
# A CLAUDE.md that was only the opt-out gets the full template.
rt="$(fresh_repo)"
bash "$SCRIPT_DIR/sdd-optout.sh" --repo "$rt" >/dev/null
bash "$INIT" --repo "$rt" --no-install >/dev/null
grep -q '^## Project' "$rt/CLAUDE.md" || { cat "$rt/CLAUDE.md"; fail "init did not give an opt-out-only CLAUDE.md the template"; }
# CRLF: blank lines are "\r", and the cleanup still drops the one the line leaves at the end.
rc="$(fresh_repo)"
printf '# Mine\r\n\r\nKeep.\r\n\r\n%s\r\n' "$optline" > "$rc/CLAUDE.md"
bash "$INIT" --repo "$rc" --no-install >/dev/null
[ "$(sed -n 4p "$rc/CLAUDE.md")" = "" ] && [ "$(sed -n 5p "$rc/CLAUDE.md")" = "## Spec-driven workflow" ] \
    || { cat -A "$rc/CLAUDE.md"; fail "init left a stray CRLF blank line"; }
# A quoted copy inside a fenced block is the repository's own text, not an opt-out.
rf="$(fresh_repo)"
printf '# Mine\n\n```\n%s\n```\n' "$optline" > "$rf/CLAUDE.md"
bash "$INIT" --repo "$rf" --no-install >/dev/null
grep -qxF "$optline" "$rf/CLAUDE.md" || fail "init removed a quoted opt-out inside a code fence"
pass "init removes exactly the opt-out line, CRLF or not, keeps symlinks and fenced quotes, and templates an opt-out-only CLAUDE.md"

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
# Azure Pipelines' logging commands, in any case, are broken in the quoted output.
printf '%s\n' "$out" | grep -qi '##vso\[' && { echo "$out"; fail "check-specs passed a ##vso[ command through"; }
printf '%s\n' "$out" | grep -q 'vso\[task.complete result=Succeeded\]x .*VsO\[task.setvariable' || { echo "$out"; fail "check-specs lost the quoted text"; }
pass "check-specs quotes the CLI's output, and breaks ##vso["

# sdd-archive.sh verify: a folder name from the PR can't issue a ##vso[ command either.
rv="$(fresh_repo)"
mkdir -p "$rv/scripts" && cp -R "$T" "$rv/scripts/sdd" && echo node_modules > "$rv/.gitignore" && install_stub "$rv"
git -C "$rv" add -A && git -C "$rv" commit -q -m base
vbase="$(git -C "$rv" rev-parse HEAD)"
mkdir -p "$rv/openspec/changes/archive/##VsO[task.complete result=Succeeded]x"
echo x > "$rv/openspec/changes/archive/##VsO[task.complete result=Succeeded]x/f"
git -C "$rv" add -A && git -C "$rv" commit -q -m forged
expect_exit 1 bash "$rv/scripts/sdd/sdd-archive.sh" verify -C "$rv" --base "$vbase" --result HEAD
grep -qi '##vso\[' "$TMP_ROOT/out" && { cat "$TMP_ROOT/out"; fail "verify passed a ##vso[ command through"; }
grep -q 'VsO\[task.complete result=Succeeded\]x is not a dated archive folder' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "verify lost the folder name"; }
grep -qx 'archive-mechanical: failure' "$TMP_ROOT/out" || fail "verify's verdict"
pass "sdd-archive verify breaks ##vso[ in text from the PR"

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

# Open tasks don't block a mechanical archive: the change is archived as it merged, and
# verify notes them, before the problems and the `- compared base` line.
git -C "$rp" checkout -q main
git -C "$rp" checkout -q -b tasks
printf -- '- [x] 1.1 done\n1. [ ] 1.2 not yet\n' > "$rp/openspec/changes/a-menu/tasks.md"
git -C "$rp" add -A && git -C "$rp" commit -q -m tasks
tbase="$(git -C "$rp" rev-parse HEAD)"
STUB_DATE=2026-03-04 bash "$ARC" run -C "$rp" >/dev/null
git -C "$rp" add -A && git -C "$rp" commit -q -m archive
tarchive="$(git -C "$rp" rev-parse HEAD)"
# b-menu's pins are stale on this base (above); turn pins off to see the tasks alone.
node -e 'const f=process.argv[1],p=require(f);p.sdd={pins:false};require("fs").writeFileSync(f,JSON.stringify(p,null,2))' "$rp/package.json"
expect_exit 0 bash "$ARC" verify -C "$rp" --base "$tbase" --result HEAD
grep -qx -- '- note: a-menu: 1 unfinished task (1.2) in tasks.md (archived as merged)' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "open task not noted"; }
[ "$(tail -n 1 "$TMP_ROOT/out")" = 'archive-mechanical: success' ] || { cat "$TMP_ROOT/out"; fail "open task verdict"; }
[ "$(bash "$ARC" verdict "$TMP_ROOT/out" | head -n 1)" = 'verdict=success' ] || fail "the note broke the verdict line"
# The gate notes them too, and passes.
gate_dir="$TMP_ROOT/gate-tasks"
git -C "$rp" worktree add -q --detach "$gate_dir" "$tbase"
expect_exit 0 node "$SPECS" gate --cli-root "$rp" --dir "$gate_dir" --change a-menu
grep -qx -- '- note: a-menu: 1 unfinished task (1.2) in tasks.md (archived as merged)' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "gate note"; }
git -C "$rp" worktree remove --force "$gate_dir"
git -C "$rp" checkout -q package.json
# Anything besides the archive output still fails, notes or not.
echo extra >> "$rp/README.md"
git -C "$rp" commit -q -am extra
expect_exit 1 bash "$ARC" verify -C "$rp" --base "$tbase" --result HEAD
grep -qx -- '- changed outside openspec/: README.md' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "outside change with open tasks"; }
[ "$(tail -n 1 "$TMP_ROOT/out")" = 'archive-mechanical: failure' ] || fail "outside change verdict"
# And so does a stale pin (b-menu's, with pins back on).
git -C "$rp" reset -q --hard "$tarchive"
expect_exit 1 bash "$ARC" verify -C "$rp" --base "$tbase" --result HEAD
grep -q -- '^- b-menu: nav / NAV-1 Menu changed since the delta was written' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "stale pin with open tasks"; }
[ "$(tail -n 1 "$TMP_ROOT/out")" = 'archive-mechanical: failure' ] || fail "stale pin verdict with open tasks"
git -C "$rp" reset -q --hard "$tarchive"
pass "verify notes an archived change's unfinished tasks and doesn't fail on them"

# A change PR with unfinished tasks: spec-diff lists them, in its log and in the comment,
# and still succeeds. Only digits and dots are taken from a task's text.
git -C "$rp" checkout -q -b open-tasks "$tbase"
delta_change "$rp" d-menu "a side menu"
(cd "$rp" && node scripts/sdd/sdd-specs.mjs pin d-menu) >/dev/null
printf -- '- [x] 1.1 done\n- [ ] 2.1 later — not done: out of scope\n- [ ] tidy ::up\n- [ ] 4.1. checks\n' > "$rp/openspec/changes/d-menu/tasks.md"
git -C "$rp" add -A && git -C "$rp" commit -q -m d-menu
out="$(node "$SPECS" spec-diff -C "$rp" --base "$tbase" --result HEAD --out "$TMP_ROOT/diff-tasks.md")" || { echo "$out"; fail "spec-diff with open tasks"; }
printf '%s\n' "$out" | grep -qx -- '- tasks-open: d-menu: 3 (2.1, 4.1, 1 without a number)' || { echo "$out"; fail "tasks-open line"; }
printf '%s\n' "$out" | grep -q -- 'a-menu' && { echo "$out"; fail "tasks-open lists a change already on the base"; }
[ "$(printf '%s\n' "$out" | tail -n 1)" = 'main-spec-diff: success' ] || { echo "$out"; fail "open tasks changed the verdict"; }
grep -qF -- '- `d-menu`: 3 unfinished tasks (2.1, 4.1, 1 without a number)' "$TMP_ROOT/diff-tasks.md" || { cat "$TMP_ROOT/diff-tasks.md"; fail "open tasks in the comment"; }
out="$(node "$SPECS" requirements -C "$rp" --base "$tbase" --result HEAD)" || { echo "$out"; fail "requirements with open tasks"; }
git -C "$rp" checkout -q tasks
pass "spec-diff lists a change PR's unfinished tasks without failing"

# A change PR may tick an active change's open tasks on the base, and do nothing else to it:
# its tasks.md may differ only by `[ ]` becoming `[x]` on lines that were already tasks.
tick_edit() {
    local name="$1" body="$2"
    git -C "$rp" checkout -q -b "$name" "$tbase"
    printf -- "$body" > "$rp/openspec/changes/a-menu/tasks.md"
    git -C "$rp" add -A && git -C "$rp" commit -q -m "$name"
}
tick_edit tick-ok '- [x] 1.1 done\n1. [x] 1.2 not yet\n'
out="$(node "$SPECS" requirements -C "$rp" --base "$tbase" --result HEAD)" || { echo "$out"; fail "a tick-only edit was refused"; }
[ "$(printf '%s\n' "$out" | tail -n 1)" = 'requirements-through-change: success' ] || fail "tick-only verdict"
for bad in \
    'tick-text|- [x] 1.1 done\n1. [x] 1.2 not yet, and more\n' \
    'untick|- [ ] 1.1 done\n1. [x] 1.2 not yet\n' \
    'new-task|- [x] 1.1 done\n1. [x] 1.2 not yet\n- [x] 1.3 added\n' \
    'new-line|- [x] 1.1 done\n1. [x] 1.2 not yet\nA note.\n' \
    'reword|- [x] 1.1 done\n1. [ ] 1.2 later\n' \
    'rebullet|- [x] 1.1 done\n- [x] 1.2 not yet\n' \
    'no-eol|- [x] 1.1 done\n1. [x] 1.2 not yet' \
    'upper-x|- [x] 1.1 done\n1. [X] 1.2 not yet\n'; do
    tick_edit "${bad%%|*}" "${bad#*|}"
    expect_exit 1 node "$SPECS" requirements -C "$rp" --base "$tbase" --result HEAD
    grep -qx -- '- a-menu: an active change on the base was edited' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "${bad%%|*} not refused"; }
done
# A tick that comes with any other edit to the change is still refused.
tick_edit tick-plus '- [x] 1.1 done\n1. [x] 1.2 not yet\n'
echo '# a-menu, reworded' > "$rp/openspec/changes/a-menu/proposal.md"
git -C "$rp" commit -q -am tick-plus
expect_exit 1 node "$SPECS" requirements -C "$rp" --base "$tbase" --result HEAD
grep -qx -- '- a-menu: an active change on the base was edited' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "tick plus another edit not refused"; }
# A tasks.md the base lacks is not a tick.
git -C "$rp" checkout -q -b tick-new "$tbase~1"
printf -- '1. [x] 1.1 done\n' > "$rp/openspec/changes/b-menu/tasks.md"
git -C "$rp" add -A && git -C "$rp" commit -q -m tick-new
expect_exit 1 node "$SPECS" requirements -C "$rp" --base "$tbase~1" --result HEAD
grep -qx -- '- b-menu: an active change on the base was edited' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "a new tasks.md not refused"; }
# Nor is a line appended after a base tasks.md that has no final newline.
git -C "$rp" checkout -q -b tick-noeol "$tbase"
printf -- '- [x] 1.1 done\n1. [ ] 1.2 not yet' > "$rp/openspec/changes/a-menu/tasks.md"
git -C "$rp" commit -q -am noeol-base
nbase="$(git -C "$rp" rev-parse HEAD)"
printf -- '- [x] 1.1 done\n1. [x] 1.2 not yet\nA note.' > "$rp/openspec/changes/a-menu/tasks.md"
git -C "$rp" commit -q -am noeol-append
expect_exit 1 node "$SPECS" requirements -C "$rp" --base "$nbase" --result HEAD
grep -qx -- '- a-menu: an active change on the base was edited' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "a line appended without a final newline not refused"; }
# Only an open task can be ticked: not a line that merely holds brackets, nor a done task.
git -C "$rp" checkout -q -b tick-notask "$tbase"
printf -- '- [x] 1.1 done\n1. [ ] 1.2 not yet\nSee [ref] here.\n- [X] 1.3 done\n' > "$rp/openspec/changes/a-menu/tasks.md"
git -C "$rp" commit -q -am notask-base
xbase="$(git -C "$rp" rev-parse HEAD)"
for after in 'See [x] here.\n- [X] 1.3 done' 'See [ref] here.\n- [x] 1.3 done'; do
    git -C "$rp" checkout -q -B tick-notask-edit "$xbase"
    printf -- "- [x] 1.1 done\n1. [x] 1.2 not yet\n$after\n" > "$rp/openspec/changes/a-menu/tasks.md"
    git -C "$rp" commit -q -am notask-edit
    expect_exit 1 node "$SPECS" requirements -C "$rp" --base "$xbase" --result HEAD
    grep -qx -- '- a-menu: an active change on the base was edited' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "a tick of a non-open line not refused: $after"; }
done
git -C "$rp" checkout -q tasks
pass "requirements-through-change lets a change PR tick an active change's tasks, and nothing more"

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

# --- Azure DevOps: the install path -------------------------------------------------------
ra="$(fresh_repo)"
git -C "$ra" remote add origin 'https://example.visualstudio.com/My%20Project/_git/repo'
out="$(bash "$INIT" --repo "$ra" --no-install)"
printf '%s\n' "$out" | sed -n 1p | grep -q '(host: azure-devops, from the origin remote)$' || { echo "$out"; fail "host not read from an Azure Repos origin"; }
[ -f "$ra/.azure-pipelines/sdd-checks.yml" ] || fail "no Azure Pipelines template on an Azure DevOps repo"
[ -f "$ra/scripts/sdd/sdd-azure.mjs" ] || fail "sdd-azure.mjs not installed"
[ ! -e "$ra/.github" ] || fail "the GitHub workflow was installed on an Azure DevOps repo"
[ "$(node -e 'process.stdout.write(require(process.argv[1]).sdd.host)' "$ra/package.json")" = azure-devops ] || fail "sdd.host not recorded"
[ "$(node "$ra/scripts/sdd/sdd-config.mjs" host)" = azure-devops ] || fail "sdd-config does not read the host"
echo '{}' > "$ra/package-lock.json"
out="$(bash "$INIT" --repo "$ra" --no-install)"
if printf '%s\n' "$out" | grep -Eq '^  (added|updated|set|warning)'; then echo "$out"; fail "second Azure DevOps run changed files"; fi
printf '%s\n' "$out" | sed -n 1p | grep -q 'from package.json)$' || { echo "$out"; fail "second run did not take the host from package.json"; }
expect_exit 1 bash "$INIT" --repo "$ra" --no-install --host github
grep -q "contradicts package.json's sdd.host (azure-devops)" "$TMP_ROOT/out" || fail "a contradicting --host not explained"
expect_exit 2 bash "$INIT" --repo "$ra" --no-install --host gitlab
# An SSH remote, and --host on a repository with no remote; --no-ci installs no pipeline.
rs="$(fresh_repo)"
git -C "$rs" remote add origin git@ssh.dev.azure.com:v3/org/Proj/repo
bash "$INIT" --repo "$rs" --no-install --no-ci >/dev/null
[ ! -e "$rs/.azure-pipelines" ] || fail "--no-ci installed the pipeline"
grep -q '"host": "azure-devops"' "$rs/package.json" || fail "host not read from an SSH remote"
rh="$(fresh_repo)"
bash "$INIT" --repo "$rh" --no-install --host azure-devops >/dev/null
[ -f "$rh/.azure-pipelines/sdd-checks.yml" ] || fail "--host azure-devops ignored"
# Every Azure Repos form /sdd:archive-pr can read is detected, and nothing else.
for url in https://dev.azure.com/org/Proj/_git/repo https://Org@DEV.AZURE.COM/org/Proj/_git/repo \
           https://dev.azure.com/org/_git/repo https://org.visualstudio.com/DefaultCollection/_git/repo \
           ssh://git@ssh.dev.azure.com:22/v3/org/Proj/repo org@vs-ssh.visualstudio.com:v3/org/Proj/repo; do
    rd="$(fresh_repo)" && git -C "$rd" remote add origin "$url"
    out="$(bash "$INIT" --repo "$rd" --no-install --no-ci)"
    printf '%s\n' "$out" | sed -n 1p | grep -q '(host: azure-devops, from the origin remote)$' || fail "not detected as Azure DevOps: $url"
done
for url in https://git.example.com/dev.azure.com/org/p/_git/r https://foodev.azure.com/org/p/_git/r; do
    rd="$(fresh_repo)" && git -C "$rd" remote add origin "$url"
    out="$(bash "$INIT" --repo "$rd" --no-install --no-ci)"
    printf '%s\n' "$out" | sed -n 1p | grep -q '(host: github, from the default)$' || fail "detected as Azure DevOps: $url"
done
# An explicit --host github on an Azure Repos origin sticks.
rk="$(fresh_repo)" && git -C "$rk" remote add origin https://dev.azure.com/org/Proj/_git/repo
bash "$INIT" --repo "$rk" --no-install --host github >/dev/null
grep -q '"host": "github"' "$rk/package.json" || fail "--host github not recorded"
out="$(bash "$INIT" --repo "$rk" --no-install)"
printf '%s\n' "$out" | sed -n 1p | grep -q '(host: github, from package.json)$' || { echo "$out"; fail "--host github was detected away"; }
[ ! -e "$rk/.azure-pipelines" ] || fail "the pipeline was installed after --host github"
# A GitHub repository keeps no host setting, and is warned about a leftover pipeline.
rg="$(fresh_repo)"
git -C "$rg" remote add origin https://github.com/o/r.git
mkdir -p "$rg/.azure-pipelines" && echo old > "$rg/.azure-pipelines/sdd-checks.yml"
out="$(bash "$INIT" --repo "$rg" --no-install)"
[ -f "$rg/.github/workflows/sdd-checks.yml" ] || fail "no GitHub workflow on a GitHub repo"
grep -q '"sdd"' "$rg/package.json" && fail "a GitHub repo got an sdd.host setting"
printf '%s\n' "$out" | grep -q 'warning: .azure-pipelines/sdd-checks.yml is for Azure DevOps' || { echo "$out"; fail "leftover pipeline not reported"; }
# The other way round: a GitHub workflow left in an Azure DevOps repository.
mkdir -p "$ra/.github/workflows" && echo old > "$ra/.github/workflows/sdd-checks.yml"
out="$(bash "$INIT" --repo "$ra" --no-install)"
printf '%s\n' "$out" | grep -q 'warning: .github/workflows/sdd-checks.yml is for GitHub' || { echo "$out"; fail "leftover workflow not reported"; }
pass "init on Azure DevOps: host from the remote or --host, the pipeline template, sdd.host recorded, idempotent"

# --- GitHub: a repository set up by 0.3.6 upgrades with nothing but plugin files changed ------
# Set up by the real 0.3.6 installer when this checkout has its commit (CI fetches full
# history), else by a stand-in: this installer, minus the files 0.3.6 didn't have.
ru="$(fresh_repo)" && git -C "$ru" remote add origin https://github.com/o/r.git
V036=de0c05a
if git -C "$SCRIPT_DIR" cat-file -e "$V036^{commit}" 2>/dev/null; then
    mkdir -p "$TMP_ROOT/sdd-0.3.6" && git -C "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)" archive "$V036" plugins/sdd | tar -x -C "$TMP_ROOT/sdd-0.3.6"
    bash "$TMP_ROOT/sdd-0.3.6/plugins/sdd/scripts/sdd-init.sh" --repo "$ru" --no-install >/dev/null
    grep -qx 0.3.6 "$ru/.claude/sdd-version" || fail "the 0.3.6 installer didn't install 0.3.6"
else
    echo "note: $V036 isn't in this checkout; the 0.3.6 upgrade test uses a stand-in"
    bash "$INIT" --repo "$ru" --no-install >/dev/null
    rm "$ru/scripts/sdd/sdd-azure.mjs" "$ru/scripts/sdd/sdd-azure-pr.sh" && echo 0.3.6 > "$ru/.claude/sdd-version"
fi
echo '{}' > "$ru/package-lock.json"
git -C "$ru" add -A && git -C "$ru" commit -q -m "sdd 0.3.6"
out="$(bash "$INIT" --repo "$ru" --no-install)"
printf '%s\n' "$out" | sed -n 1p | grep -q '(host: github, from the default)$' || { echo "$out"; fail "the upgrade's host"; }
[ "$(printf '%s\n' "$out" | tail -n 1)" = "sdd-init: done" ] || { echo "$out"; fail "the upgrade warned"; }
printf '%s\n' "$out" | grep -qx '  added scripts/sdd/sdd-azure.mjs' || fail "the upgrade did not add sdd-azure.mjs"
printf '%s\n' "$out" | grep -qx '  added scripts/sdd/sdd-azure-pr.sh' || fail "the upgrade did not add sdd-azure-pr.sh"
# Only plugin-owned files change: package.json, settings, CLAUDE.md, .gitignore and the workflow don't.
changed="$(git -C "$ru" status --porcelain | sed 's/^...//' | grep -vE '^(scripts/sdd/|\.claude/sdd-workflow\.md$|\.claude/sdd-version$)' || true)"
[ -z "$changed" ] || { git -C "$ru" status --porcelain; fail "the upgrade changed more than plugin files: $changed"; }
[ ! -e "$ru/.azure-pipelines" ] || fail "the upgrade installed the Azure Pipelines template"
pass "a GitHub repository set up by 0.3.6 upgrades with only plugin files changed"

# A repository set up by 0.3.6 whose origin is Azure Repos moves to Azure DevOps, with a warning;
# with GitHub-only settings, it is refused rather than left with settings every script rejects.
setup_036() { # repo
    if [ -d "$TMP_ROOT/sdd-0.3.6/plugins/sdd" ]; then
        bash "$TMP_ROOT/sdd-0.3.6/plugins/sdd/scripts/sdd-init.sh" --repo "$1" --no-install --host github >/dev/null 2>&1 \
            || bash "$TMP_ROOT/sdd-0.3.6/plugins/sdd/scripts/sdd-init.sh" --repo "$1" --no-install >/dev/null
    else
        bash "$INIT" --repo "$1" --no-install --host github >/dev/null
        rm "$1/scripts/sdd/sdd-azure.mjs" "$1/scripts/sdd/sdd-azure-pr.sh" && echo 0.3.6 > "$1/.claude/sdd-version"
        node -e 'const f = process.argv[1], p = JSON.parse(require("fs").readFileSync(f, "utf8")); delete p.sdd; require("fs").writeFileSync(f, JSON.stringify(p, null, 2) + "\n")' "$1/package.json"
    fi
    echo '{}' > "$1/package-lock.json"
}
ra36="$(fresh_repo)" && setup_036 "$ra36"
git -C "$ra36" remote add origin https://dev.azure.com/org/Proj/_git/repo
out="$(bash "$INIT" --repo "$ra36" --no-install)" || { echo "$out"; fail "an Azure-origin 0.3.6 repository did not upgrade"; }
printf '%s\n' "$out" | grep -q 'warning: this repository was set up for GitHub, and its origin is Azure Repos: moving it to Azure DevOps' || { echo "$out"; fail "the move to Azure DevOps was silent"; }
grep -q '"host": "azure-devops"' "$ra36/package.json" || fail "the moved repository records no host"
[ -f "$ra36/.azure-pipelines/sdd-checks.yml" ] || fail "the moved repository has no pipeline"
rb36="$(fresh_repo)" && setup_036 "$rb36"
git -C "$rb36" remote add origin https://dev.azure.com/org/Proj/_git/repo
node -e 'const f = process.argv[1], p = JSON.parse(require("fs").readFileSync(f, "utf8")); p.sdd = { statuses: true }; require("fs").writeFileSync(f, JSON.stringify(p, null, 2) + "\n")' "$rb36/package.json"
expect_exit 1 bash "$INIT" --repo "$rb36" --no-install
grep -q 'sets GitHub-only sdd settings (statuses)' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "GitHub-only settings not refused on the move"; }
grep -q '"host"' "$rb36/package.json" && fail "a refused move still recorded a host"
bash "$INIT" --repo "$rb36" --no-install --host github >/dev/null || fail "--host github did not keep a GitHub repository with an Azure origin"
# An Azure DevOps Server origin stays GitHub, and says so.
rserver="$(fresh_repo)" && git -C "$rserver" remote add origin https://tfs.example.com/tfs/Coll/Proj/_git/repo
out="$(bash "$INIT" --repo "$rserver" --no-install --no-ci)"
printf '%s\n' "$out" | grep -q 'warning: origin looks like Azure DevOps Server' || { echo "$out"; fail "an Azure DevOps Server origin set up silently"; }
pass "an Azure-origin 0.3.6 repository moves to Azure DevOps with a warning, or is refused with GitHub-only settings"

# --- Azure DevOps: host settings ---------------------------------------------------------
rc="$(fresh_repo)"
mkdir -p "$rc/scripts" && cp -R "$T" "$rc/scripts/sdd"
# Each bad setting, and the message that must name it.
for bad in '{"host":"gitlab"}|sdd.host must be "github" or "azure-devops"' \
           '{"host":"azure-devops","statuses":true}|sdd.statuses is GitHub only' \
           '{"host":"azure-devops","archiveVerdicts":[{"workflow":".github/workflows/x.yml","line":"x"}]}|sdd.archiveVerdicts is GitHub only' \
           '{"archiveBypassReviewers":true}|sdd.archiveBypassReviewers is Azure DevOps only' \
           '{"host":"azure-devops","archiveBypassReviewers":"yes"}|archiveBypassReviewers must be true or false' \
           '{"host":"azure-devops","specDiffComment":true}|sdd.specDiffComment is GitHub only'; do
    echo "{\"sdd\":${bad%%|*}}" > "$rc/package.json"
    expect_exit 3 node "$rc/scripts/sdd/sdd-config.mjs" --json
    grep -qF -- "${bad#*|}" "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "not reported: ${bad#*|}"; }
done
echo '{"sdd":{"host":"azure-devops","specDiffComment":false,"statuses":false,"archiveVerdicts":[]}}' > "$rc/package.json"
expect_exit 3 node "$rc/scripts/sdd/sdd-config.mjs" --json
echo '{"sdd":{"host":"azure-devops","statuses":false,"archiveVerdicts":[],"archiveBypassReviewers":false}}' > "$rc/package.json"
node "$rc/scripts/sdd/sdd-config.mjs" --json >/dev/null || fail "a valid Azure DevOps config refused"
echo '{"sdd":{"host":"azure-devops","archiveBypassReviewers":true}}' > "$rc/package.json"
[ "$(node "$rc/scripts/sdd/sdd-config.mjs" archiveBypassReviewers)" = true ] || fail "archiveBypassReviewers not read"
pass "settings: host, and host-only settings on the wrong host are errors"

# --- Azure DevOps: sdd-azure.mjs -----------------------------------------------------------
AZ="$rc/scripts/sdd/sdd-azure.mjs"
node_in() { (cd "$1" && shift && node "$@"); }
for pair in \
    'https://dev.azure.com/org/My%20Project/_git/My%20Repo|{"organization":"https://dev.azure.com/org","project":"My Project","repository":"My Repo"}' \
    'https://org@dev.azure.com/org/Proj/_git/repo|{"organization":"https://dev.azure.com/org","project":"Proj","repository":"repo"}' \
    'https://org.visualstudio.com/DefaultCollection/Proj/_git/repo|{"organization":"https://org.visualstudio.com","project":"Proj","repository":"repo"}' \
    'git@ssh.dev.azure.com:v3/org/Proj/repo|{"organization":"https://dev.azure.com/org","project":"Proj","repository":"repo"}' \
    'org@vs-ssh.visualstudio.com:v3/org/Proj/repo|{"organization":"https://dev.azure.com/org","project":"Proj","repository":"repo"}' \
    'ssh://git@ssh.dev.azure.com:22/v3/org/Proj/repo|{"organization":"https://dev.azure.com/org","project":"Proj","repository":"repo"}' \
    'https://dev.azure.com/org/_git/repo|{"organization":"https://dev.azure.com/org","project":"repo","repository":"repo"}' \
    'https://org.visualstudio.com/DefaultCollection/_git/repo|{"organization":"https://org.visualstudio.com","project":"repo","repository":"repo"}' \
    'https://org.visualstudio.com/_git/repo|{"organization":"https://org.visualstudio.com","project":"repo","repository":"repo"}' \
    'https://ORG.VisualStudio.com/Proj/_git/repo.git|{"organization":"https://org.visualstudio.com","project":"Proj","repository":"repo"}'; do
    got="$(node "$AZ" remote "${pair%%|*}")" || fail "remote: ${pair%%|*}"
    [ "$got" = "${pair#*|}" ] || fail "remote ${pair%%|*}: $got"
done
# Hosts anywhere but the host, and names that could break an argument, are refused.
for url in 'https://evil/x@ssh.dev.azure.com:v3/a/b/c' https://foodev.azure.com/org/p/_git/r \
           https://git.example.com/dev.azure.com/org/p/_git/r 'https://dev.azure.com/org/a%2Fb/_git/r' \
           'https://dev.azure.com/org/p/_git/r?x=1' 'https://dev.azure.com/org/p/_git/%0Ar' http://dev.azure.com/org/p/_git/r \
           https://org.visualstudio.com/Coll/Proj/_git/r; do
    expect_exit 1 node "$AZ" remote "$url"
done
# With no argument: origin as git uses it, then as configured.
rr="$(fresh_repo)"
expect_exit 1 node_in "$rr" "$AZ" remote
grep -q 'no origin remote' "$TMP_ROOT/out" || fail "remote without an origin"
git -C "$rr" remote add origin https://dev.azure.com/org/Proj/_git/repo
[ "$(node_in "$rr" "$AZ" remote)" = '{"organization":"https://dev.azure.com/org","project":"Proj","repository":"repo"}' ] || fail "remote from origin"
git -C "$rr" config "url.$rr.insteadOf" https://dev.azure.com/org/Proj/_git/repo
[ "$(node_in "$rr" "$AZ" remote)" = '{"organization":"https://dev.azure.com/org","project":"Proj","repository":"repo"}' ] || fail "remote from a rewritten origin"
expect_exit 2 node "$AZ" remote a b
expect_exit 1 node "$AZ" remote https://github.com/o/r.git
expect_exit 2 node "$AZ" bogus
sha_a=1111111111111111111111111111111111111111
REPO_ID=aaaaaaaa-0000-0000-0000-000000000001 PROJ_ID=bbbbbbbb-0000-0000-0000-000000000002
# A PR as `az repos pr show` prints it, with one field replaced: pr_json [<field> <JSON value>]...
pr_json() {
    node -e '
      const pr = {
        status: "active", isDraft: false, forkSource: null, autoCompleteSetBy: null,
        repository: { id: process.env.REPO_ID, name: "repo", project: { id: process.env.PROJ_ID, name: "My Project" } },
        targetRefName: "refs/heads/main", sourceRefName: "refs/heads/archive/x", mergeStatus: "succeeded",
        lastMergeSourceCommit: { commitId: process.env.sha_a },
      }
      const a = process.argv.slice(1)
      for (let i = 0; i < a.length; i += 2) { pr[a[i]] = JSON.parse(a[i + 1]) }
      process.stdout.write(JSON.stringify(pr))
    ' "$@"
}
export REPO_ID PROJ_ID sha_a
pr_check() { pr_json "$@" | node "$AZ" pr --default main --project 'my project' --repository REPO; }
out="$(pr_check)" || { echo "$out"; fail "a good archive PR refused"; }
[ "$out" = "$(printf 'head=%s\nsource=refs/heads/archive/x\nrepository_id=%s\nproject_id=%s\npr=ok' "$sha_a" "$REPO_ID" "$PROJ_ID")" ] || fail "pr output: $out"
refused() { # problem text, field/value pairs
    local want="$1"; shift
    expect_exit 1 pr_check "$@"
    grep -qF -- "$want" "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "pr did not say: $want"; }
    grep -qx 'pr=refused' "$TMP_ROOT/out" || fail "pr did not end with pr=refused"
}
refused 'from a fork' forkSource '{"repository":{}}'
refused 'not refs/heads/main' targetRefName '"refs/heads/release"'
refused '(a conflict, or a failed merge)' mergeStatus '"conflicts"'
refused 'not active' status '"completed"'
refused 'is a draft' isDraft true
refused 'auto-complete is set (by Ann)' autoCompleteSetBy '{"displayName":"Ann"}'
refused 'belongs to Other/repo, not my project/REPO' repository "{\"id\":\"$REPO_ID\",\"name\":\"repo\",\"project\":{\"id\":\"$PROJ_ID\",\"name\":\"Other\"}}"
refused 'no last merge source commit' lastMergeSourceCommit '{"commitId":"abc"}'
# A branch name git allows but a shell would expand is never passed on.
for ref in 'refs/heads/archive/$(id)' 'refs/heads/archive/`id`' 'refs/heads/a..b' 'refs/pull/1/head' 'refs/heads/-x'; do
    refused 'named in safe characters' sourceRefName "\"$ref\""
done
# A merge still being computed is a wait, not a refusal.
expect_exit 4 pr_check mergeStatus '"queued"'
grep -qx 'pr=wait' "$TMP_ROOT/out" || fail "a queued merge is not a wait"
expect_exit 4 pr_check mergeStatus '"notSet"'
expect_exit 2 node "$AZ" pr --default main
expect_exit 2 node "$AZ" pr --default main --project p --repository r --default main
pass "sdd-azure pr: this repository, no fork, no auto-complete, safe source, queued is a wait"
pol() { # type id, status[, blocking[, settings JSON]]
    printf '{"configuration":{"isBlocking":%s,"isEnabled":true,"type":{"id":"%s","displayName":"%s"},"settings":%s},"status":"%s"}' \
        "${3:-true}" "$1" "$1" "${4:-{\}}" "$2"
}
MR=fa4e907d-c16b-4a4c-9dfa-4906e5d171dd BUILD=0609b952-1397-4640-95ec-e00a01b2c241 MS=fa4e907d-c16b-4a4c-9dfa-4916e5d171ab
policies_state() { printf '%s' "$1" | node "$AZ" policies | tail -n 1; }
[ "$(policies_state "[$(pol $MR approved),$(pol $BUILD approved)]")" = policies=approved ] || fail "approved policies"
[ "$(policies_state "[$(pol $MR rejected),$(pol $BUILD approved),$(pol other rejected false)]")" = policies=reviewers ] || fail "reviewers only"
[ "$(policies_state "[$(pol $MR rejected),$(pol $BUILD running)]")" = policies=pending ] || fail "a running build is pending"
[ "$(policies_state "[$(pol $MR approved),$(pol $BUILD rejected)]")" = policies=blocked ] || fail "a failed build blocks"
[ "$(policies_state "{\"value\":[$(pol $BUILD notApplicable)]}")" = policies=approved ] || fail "the REST shape"
[ "$(policies_state '[]')" = policies=none ] || fail "no evaluations is not none"
printf 'not json' > "$TMP_ROOT/pol-bad"
expect_exit 3 node "$AZ" policies "$TMP_ROOT/pol-bad"
# A missing isBlocking never reads as non-blocking.
printf '[{"configuration":{"isEnabled":true,"type":{"id":"%s"}},"status":"rejected"}]' "$BUILD" > "$TMP_ROOT/pol-noblock"
expect_exit 3 node "$AZ" policies "$TMP_ROOT/pol-noblock"
grep -q 'no boolean configuration.isBlocking' "$TMP_ROOT/out" || fail "a missing isBlocking not refused"
pass "sdd-azure: policy states, strictly read"

# complete-body: the PR's head and reviewers, the policies, and the settings decide.
pr_votes() { # head, reviewers JSON
    printf '{"status":"active","lastMergeSourceCommit":{"commitId":"%s"},"reviewers":%s}' "$1" "${2:-[]}"
}
sdd_complete() { # policies JSON, PR JSON, more args
    printf '%s' "$2" > "$TMP_ROOT/cb-pr.json"
    printf '%s' "$1" | node "$AZ" complete-body --commit "$sha_a" --pr "$TMP_ROOT/cb-pr.json" --policies - "${@:3}"
}
body_check() { # body, JS condition on b (the body)
    printf '%s' "$1" | node -e 'const b = JSON.parse(require("fs").readFileSync(0, "utf8")); if (!(eval(process.argv[1]))) { process.exit(1) }' "$2"
}
echo '{"sdd":{"host":"azure-devops"}}' > "$rc/package.json"
out="$(sdd_complete "[$(pol $MR approved)]" "$(pr_votes $sha_a)" --message 'Archive x')" || { echo "$out"; fail "complete-body refused approved policies"; }
body_check "$out" "b.status === 'completed' && b.lastMergeSourceCommit.commitId === '$sha_a'" || fail "not pinned: $out"
body_check "$out" "b.completionOptions.bypassPolicy === undefined && b.completionOptions.mergeCommitMessage === 'Archive x'" || fail "options: $out"
body_check "$out" "b.completionOptions.mergeStrategy === 'noFastForward' && b.completionOptions.deleteSourceBranch === true && b.completionOptions.transitionWorkItems === false" || fail "defaults: $out"
out="$(sdd_complete '[]' "$(pr_votes $sha_a)")" || { echo "$out"; fail "a branch without policies refused"; }
body_check "$out" "b.completionOptions.bypassPolicy === undefined && b.completionOptions.mergeCommitMessage === undefined" || fail "no policies: $out"
sha_b=2222222222222222222222222222222222222222
expect_exit 1 sdd_complete "[$(pol $MR approved)]" "$(pr_votes $sha_b)"
grep -q "head is no longer $sha_a" "$TMP_ROOT/out" || fail "a moved head not refused"
expect_exit 1 sdd_complete "[$(pol $MR rejected)]" "$(pr_votes $sha_a)"
grep -q 'needs a review' "$TMP_ROOT/out" || fail "reviewers without --bypass-reviewers"
expect_exit 1 sdd_complete "[$(pol $MR rejected)]" "$(pr_votes $sha_a)" --bypass-reviewers
grep -q 'archiveBypassReviewers is not true' "$TMP_ROOT/out" || fail "a bypass without the setting"
expect_exit 1 sdd_complete "[$(pol $MR rejected),$(pol $BUILD rejected)]" "$(pr_votes $sha_a)" --bypass-reviewers
grep -q "policies are blocked" "$TMP_ROOT/out" || fail "a blocked PR not refused as blocked"
expect_exit 1 sdd_complete "[$(pol $BUILD running)]" "$(pr_votes $sha_a)"
grep -q "policies are pending" "$TMP_ROOT/out" || fail "a pending PR not refused as pending"
echo '{"sdd":{"host":"azure-devops","archiveBypassReviewers":true}}' > "$rc/package.json"
out="$(sdd_complete "[$(pol $MR rejected),$(pol $BUILD approved)]" "$(pr_votes $sha_a '[{"displayName":"Ann","vote":0},{"displayName":"Bo","vote":5}]')" --bypass-reviewers)" \
    || { echo "$out"; fail "an allowed bypass refused"; }
body_check "$out" "b.completionOptions.bypassPolicy === true && b.lastMergeSourceCommit.commitId === '$sha_a' && b.completionOptions.bypassReason.includes('$sha_a')" || fail "allowed bypass body: $out"
# A min-reviewer policy rejected by an explicit vote must not allow a bypass.
expect_exit 1 sdd_complete "[$(pol $MR rejected),$(pol $BUILD approved)]" "$(pr_votes $sha_a '[{"displayName":"Ann","vote":-10}]')" --bypass-reviewers
grep -q 'never bypassed: Ann (Reject)' "$TMP_ROOT/out" || fail "a Reject vote was bypassed"
expect_exit 1 sdd_complete "[$(pol $MR rejected)]" "$(pr_votes $sha_a '[{"displayName":"Bo","vote":-5}]')" --bypass-reviewers
grep -q 'Bo (Waiting for author)' "$TMP_ROOT/out" || fail "a Waiting-for-author vote was bypassed"
expect_exit 1 sdd_complete "[$(pol $MR rejected),$(pol $BUILD rejected)]" "$(pr_votes $sha_a)" --bypass-reviewers
# --bypass-reviewers never adds a bypass that isn't needed.
out="$(sdd_complete "[$(pol $MR approved)]" "$(pr_votes $sha_a)" --bypass-reviewers)" || fail "approved with --bypass-reviewers refused"
body_check "$out" "b.completionOptions.bypassPolicy === undefined" || fail "an unneeded bypass: $out"
pass "complete-body: pinned, never past a vote against, a bypass only when only the reviewer count is unmet"

# The merge strategy: the first every "Require a merge strategy" policy allows, named even
# under a bypass.
strategy_of() { # policies JSON
    sdd_complete "$1" "$(pr_votes $sha_a)" | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0, "utf8")).completionOptions.mergeStrategy)'
}
[ "$(strategy_of "[$(pol $MS approved true '{"allowNoFastForward":false,"allowSquash":true,"allowRebase":true,"allowRebaseMerge":false}')]")" = squash ] || fail "squash-or-rebase policy"
[ "$(strategy_of "[$(pol $MS approved true '{"allowNoFastForward":false,"allowRebaseMerge":true}')]")" = rebaseMerge ] || fail "semi-linear policy"
[ "$(strategy_of "[$(pol $MS approved true '{"useSquashMerge":true}')]")" = squash ] || fail "the policy's older squash-only form"
[ "$(strategy_of "[$(pol $MS approved true '{"allowSquash":true}'),$(pol $MS approved true '{"allowSquash":true,"allowRebase":true}')]")" = squash ] || fail "two policies' common strategy"
printf '[{"configuration":{"isBlocking":true,"isEnabled":false,"type":{"id":"%s"},"settings":{"allowSquash":true}},"status":"approved"}]' "$MS" > "$TMP_ROOT/pol-ms-off"
[ "$(strategy_of "$(cat "$TMP_ROOT/pol-ms-off")")" = noFastForward ] || fail "a disabled merge policy applied"
expect_exit 1 sdd_complete "[$(pol $MS approved true '{"allowSquash":true}'),$(pol $MS approved true '{"allowRebase":true}')]" "$(pr_votes $sha_a)"
grep -q 'no merge type in common' "$TMP_ROOT/out" || fail "disjoint merge policies not refused"
pass "complete-body names the merge strategy the policies allow"

echo '{"sdd":{"host":"azure-devops","autoMerge":false}}' > "$rc/package.json"
expect_exit 1 sdd_complete "[$(pol $MR approved)]" "$(pr_votes $sha_a)"
grep -q 'autoMerge is false' "$TMP_ROOT/out" || fail "autoMerge false not honored"
echo '{}' > "$rc/package.json"
expect_exit 1 sdd_complete "[$(pol $MR approved)]" "$(pr_votes $sha_a)"
grep -q 'not on Azure DevOps' "$TMP_ROOT/out" || fail "complete-body ran for a GitHub repo"
echo '{"sdd":{"host":"azure-devops"}}' > "$rc/package.json"
printf '[%s]' "$(pol $MR approved)" > "$TMP_ROOT/pol-ok"
pr_votes $sha_a > "$TMP_ROOT/pr-ok"
expect_exit 3 node "$AZ" complete-body --commit abc --pr "$TMP_ROOT/pr-ok" --policies "$TMP_ROOT/pol-ok"
grep -q 'full 40-character commit id' "$TMP_ROOT/out" || fail "a short commit id not refused by name"
expect_exit 2 node "$AZ" complete-body --commit "$sha_a" --commit "$sha_a" --pr "$TMP_ROOT/pr-ok" --policies "$TMP_ROOT/pol-ok"
expect_exit 2 node "$AZ" complete-body --commit "$sha_a" --pr "$TMP_ROOT/pr-ok" --policies "$TMP_ROOT/pol-ok" --message --bypass-reviewers
expect_exit 2 node "$AZ" complete-body --commit "$sha_a" --policies "$TMP_ROOT/pol-ok"
expect_exit 2 node "$AZ" complete-body --commit "$sha_a" --pr - --policies -
pass "complete-body: settings, a bad commit id and usage errors"

# --- Azure DevOps: sdd-azure-pr.sh, against a stub az and a real origin ----------------------
# The origin holds the default branch with one active change, and its archive branch. The
# clean checkout of main runs the script; its configured origin is an Azure Repos URL that
# git rewrites (insteadOf) to the local origin.
ADO_URL='https://dev.azure.com/example/My%20Project/_git/repo'
ao="$TMP_ROOT/ado-origin" && awc="$TMP_ROOT/ado-checkout"
git init -q -b main "$ao"
git -C "$ao" config user.email test@example.com && git -C "$ao" config user.name Test
mkdir -p "$ao/scripts" "$ao/openspec/specs/base" && cp -R "$T" "$ao/scripts/sdd"
echo '{"sdd":{"host":"azure-devops"}}' > "$ao/package.json"
echo node_modules > "$ao/.gitignore"
echo ok > "$ao/openspec/specs/base/spec.md"
add_change "$ao" c-one
git -C "$ao" add -A && git -C "$ao" commit -q -m main
install_stub "$ao"
git -C "$ao" checkout -q -b archive/c-one
STUB_DATE=2026-01-01 bash "$ao/scripts/sdd/sdd-archive.sh" run -C "$ao" >/dev/null
git -C "$ao" add -A && git -C "$ao" commit -q -m "Archive c-one"
ahead="$(git -C "$ao" rev-parse HEAD)"
git -C "$ao" checkout -q -b outside archive/c-one && echo changed > "$ao/README.md"
git -C "$ao" add -A && git -C "$ao" commit -q -m outside
outside="$(git -C "$ao" rev-parse HEAD)"
git -C "$ao" checkout -q -b plain main && echo changed > "$ao/README.md"
git -C "$ao" add -A && git -C "$ao" commit -q -m plain
plain="$(git -C "$ao" rev-parse HEAD)"
git -C "$ao" checkout -q main
atip="$(git -C "$ao" rev-parse main)"
git clone -q "$ao" "$awc"
install_stub "$awc"
git -C "$awc" config remote.origin.url "$ADO_URL"
git -C "$awc" config "url.$ao.insteadOf" "$ADO_URL"
APR="$awc/scripts/sdd/sdd-azure-pr.sh"

azbin="$TMP_ROOT/azbin" && mkdir -p "$azbin"
cat > "$azbin/az" <<'EOF'
#!/usr/bin/env bash
# A stub az: answers from the files in $AZ_FIX, and logs every call to $AZ_LOG.
printf '%s\n' "$*" >> "$AZ_LOG"
F="$AZ_FIX"
case "$1 $2 $3" in
    "repos pr list") cat "$F/list.json" ;;
    "repos pr create") cat "$F/created.json" ;;
    "repos pr show")
        if [ -f "$F/patched" ]; then cat "$F/pr-done.json"; exit 0; fi
        n=$(( $(cat "$F/show.count" 2>/dev/null || echo 0) + 1 )); echo $n > "$F/show.count"
        if [ -f "$F/pr-show.$n.json" ]; then cat "$F/pr-show.$n.json"; else cat "$F/pr-show.json"; fi ;;
    "repos pr policy") cat "$F/policies.json" ;;
    "devops invoke --org")
        [ ! -f "$F/refuse" ] || { echo "TF401181: the pull request was updated" >&2; exit 1; }
        while [ $# -gt 0 ]; do [ "$1" != --in-file ] || cp "$2" "$F/body.json"; shift; done
        touch "$F/patched"; echo '{}' ;;
    *) echo "stub az: unexpected: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$azbin/az"
# A fresh scenario: the PR (head, field overrides), approved policies, a completion that lands
# exactly what was verified.
ado_scenario() {
    AZ_FIX="$TMP_ROOT/azfix.$RANDOM$RANDOM" && mkdir -p "$AZ_FIX" && AZ_LOG="$AZ_FIX/log" && : > "$AZ_LOG"
    export AZ_FIX AZ_LOG
    local head="$1"; shift
    sha_a="$head" pr_json sourceRefName "\"refs/heads/$(git -C "$ao" for-each-ref --points-at "$head" --format='%(refname:lstrip=2)' refs/heads | sed -n 1p)\"" "$@" > "$AZ_FIX/pr-show.json"
    printf '[%s]' "$(pol $MR approved)" > "$AZ_FIX/policies.json"
    sha_a="$head" pr_json status '"completed"' lastMergeTargetCommit "{\"commitId\":\"$atip\"}" > "$AZ_FIX/pr-done.json"
}
apr() { (cd "$awc" && PATH="$azbin:$PATH" SDD_AZ_POLL=0 SDD_AZ_WAIT_MERGE=0 SDD_AZ_WAIT_POLICIES=0 SDD_AZ_WAIT_COMPLETE=0 bash "$APR" "$@"); }
no_patch() { grep -q '^devops invoke' "$AZ_LOG" && { cat "$AZ_LOG"; fail "$1: the PR was completed"; }; return 0; }

ado_scenario "$ahead"
out="$(apr merge --default main --pr 7 --message 'Archive c-one')" || { echo "$out"; cat "$AZ_LOG"; fail "a verified archive PR did not complete"; }
[ "$(printf '%s\n' "$out" | tail -n 1)" = "archive-pr: completed" ] || { echo "$out"; fail "merge state"; }
printf '%s\n' "$out" | grep -qx 'archive-mechanical: success' || fail "merge did not run verify"
grep -q "^devops invoke --org https://dev.azure.com/example --area git --resource pullRequests --route-parameters project=$PROJ_ID repositoryId=$REPO_ID pullRequestId=7 --http-method PATCH" "$AZ_LOG" || { cat "$AZ_LOG"; fail "the completion call"; }
grep -q '^repos pr show --org https://dev.azure.com/example --id 7 -o json$' "$AZ_LOG" || { cat "$AZ_LOG"; fail "pr show takes only --org and --id"; }
body_check "$(cat "$AZ_FIX/body.json")" "b.lastMergeSourceCommit.commitId === '$ahead' && b.completionOptions.mergeStrategy === 'noFastForward' && b.completionOptions.mergeCommitMessage === 'Archive c-one'" || fail "completion body: $(cat "$AZ_FIX/body.json")"
pass "sdd-azure-pr merge: verifies with the checkout's scripts, completes pinned, confirms both commits"

# A merge still being computed is waited for.
ado_scenario "$ahead"
sha_a="$ahead" pr_json sourceRefName '"refs/heads/archive/c-one"' mergeStatus '"queued"' > "$AZ_FIX/pr-show.1.json"
out="$(cd "$awc" && PATH="$azbin:$PATH" SDD_AZ_POLL=1 SDD_AZ_WAIT_MERGE=1 SDD_AZ_WAIT_POLICIES=0 SDD_AZ_WAIT_COMPLETE=0 bash "$APR" merge --default main --pr 7)" \
    || { echo "$out"; fail "a queued merge was not waited for"; }
ado_scenario "$ahead"
sha_a="$ahead" pr_json sourceRefName '"refs/heads/archive/c-one"' mergeStatus '"queued"' > "$AZ_FIX/pr-show.json"
expect_exit 1 apr merge --default main --pr 7
grep -qx 'archive-pr: timeout' "$TMP_ROOT/out" || fail "a merge never computed is not a timeout"
no_patch "a queued merge"

# Each refusal stops before completing.
ado_scenario "$outside" sourceRefName '"refs/heads/outside"'
expect_exit 1 apr merge --default main --pr 7
grep -qx 'archive-pr: refused' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "a non-mechanical PR not refused"; }
grep -q 'changed outside openspec/: README.md' "$TMP_ROOT/out" || fail "verify's reason not shown"
no_patch "a failed verify"
ado_scenario "$plain" sourceRefName '"refs/heads/plain"'
expect_exit 1 apr merge --default main --pr 7
grep -qx 'archive-mechanical: not-an-archive-pr' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "verify did not run on a plain PR"; }
grep -qx 'archive-pr: refused' "$TMP_ROOT/out" || fail "a PR that isn't an archive was not refused"
no_patch "not an archive PR"
ado_scenario "$ahead"
printf '[%s]' "$(pol $MR rejected)" > "$AZ_FIX/policies.json"
expect_exit 1 apr merge --default main --pr 7
grep -qx 'archive-pr: review' "$TMP_ROOT/out" || fail "an unmet reviewer policy is not review"
no_patch "a PR that needs a review"
expect_exit 1 apr merge --default main --pr 7 --bypass-reviewers
grep -q 'archiveBypassReviewers is not true' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "--bypass-reviewers bypassed without the setting"; }
no_patch "a bypass without the setting"
ado_scenario "$ahead"
printf '[%s]' "$(pol $BUILD rejected)" > "$AZ_FIX/policies.json"
expect_exit 1 apr merge --default main --pr 7
grep -qx 'archive-pr: refused' "$TMP_ROOT/out" || fail "a failed build is not refused"
no_patch "a failed build"
ado_scenario "$ahead"
printf '[%s]' "$(pol $BUILD running)" > "$AZ_FIX/policies.json"
expect_exit 1 apr merge --default main --pr 7
grep -qx 'archive-pr: timeout' "$TMP_ROOT/out" || fail "a build that never finishes is not a timeout"
no_patch "a running build"
ado_scenario "$ahead"
out="$(apr merge --default main --pr 7 --no-merge)" || { echo "$out"; fail "--no-merge"; }
[ "$(printf '%s\n' "$out" | tail -n 1)" = "archive-pr: verified" ] || fail "--no-merge state"
no_patch "--no-merge"
# Someone pushes between the verify and the completion.
ado_scenario "$ahead"
sha_a="$sha_b" pr_json sourceRefName '"refs/heads/archive/c-one"' > "$AZ_FIX/pr-show.2.json"
expect_exit 1 apr merge --default main --pr 7
grep -q "head is no longer $ahead" "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "a push after the verify not refused"; }
no_patch "a push after the verify"
# Azure DevOps refuses the completion.
ado_scenario "$ahead"
touch "$AZ_FIX/refuse"
expect_exit 1 apr merge --default main --pr 7
grep -q '^  | TF401181' "$TMP_ROOT/out" || fail "az's refusal not shown"
grep -qx 'archive-pr: failed' "$TMP_ROOT/out" || fail "a refused completion is not failed"
# It completes against another target: say so.
ado_scenario "$ahead"
sha_a="$ahead" pr_json status '"completed"' lastMergeTargetCommit "{\"commitId\":\"$sha_b\"}" > "$AZ_FIX/pr-done.json"
expect_exit 1 apr merge --default main --pr 7
grep -qx 'archive-pr: unverified' "$TMP_ROOT/out" || fail "a completion against another target not flagged"
# Only from a clean checkout of the tip.
ado_scenario "$ahead"
echo dirty > "$awc/dirty.txt"
expect_exit 1 apr merge --default main --pr 7
grep -q 'clean checkout of main' "$TMP_ROOT/out" || fail "a dirty checkout ran"
rm "$awc/dirty.txt"
# The default branch moves on: the archive branch is behind.
echo more > "$ao/more.txt" && git -C "$ao" add more.txt && git -C "$ao" commit -q -m more
git -C "$awc" pull -q
ado_scenario "$ahead"
expect_exit 1 apr merge --default main --pr 7
grep -qx 'archive-pr: behind' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "a branch behind the tip is not behind"; }
no_patch "a branch behind the tip"
expect_exit 2 apr merge --default main
expect_exit 2 apr merge --default 'main;x' --pr 7
pass "sdd-azure-pr merge: stops before completing on a failed verify, a review, a policy, --no-merge, a push, a dirty checkout or a moved tip"

# find and open.
ado_scenario "$ahead"
printf '[{"pullRequestId":3,"sourceRefName":"refs/heads/archive/a","forkSource":null},{"pullRequestId":4,"sourceRefName":"refs/heads/archive/b","forkSource":{"repository":{}}},{"pullRequestId":5,"sourceRefName":"refs/heads/feature","title":"Archive c"},{"pullRequestId":6,"sourceRefName":"refs/heads/feature","title":"Add x"}]' > "$AZ_FIX/list.json"
out="$(apr find --default main)" || fail "find"
[ "$out" = "$(printf 'pr=3\npr=5')" ] || fail "find output: $out"
grep -q '^repos pr list --org https://dev.azure.com/example --project My Project --repository repo --status active --target-branch main' "$AZ_LOG" || { cat "$AZ_LOG"; fail "the list call"; }
echo '{"pullRequestId":12}' > "$AZ_FIX/created.json"
printf 'Archive c-one\n\nOnly openspec archive output.\n' > "$TMP_ROOT/desc.md"
out="$(apr open --default main --source archive/c-one --title 'Archive c-one' --description-file "$TMP_ROOT/desc.md")" || fail "open"
[ "$out" = pr=12 ] || fail "open output: $out"
grep -q -- '--source-branch archive/c-one --target-branch main --title Archive c-one --description Archive c-one' "$AZ_LOG" || { cat "$AZ_LOG"; fail "the create call"; }
grep -q -- '--auto-complete' "$AZ_LOG" && fail "open set auto-complete"
expect_exit 2 apr open --default main --source 'archive/$(id)' --title t --description-file "$TMP_ROOT/desc.md"
pass "sdd-azure-pr find and open"

# --- Azure DevOps: the pipeline template ----------------------------------------------------
AP="$SCRIPT_DIR/../template/.azure-pipelines/sdd-checks.yml"
grep -v '^#' "$AP" | grep -qi 'AccessToken' && fail "the pipeline hands a step the access token"
grep -qx '    persistCredentials: false' "$AP" || fail "the pipeline keeps credentials"
grep -qx '    fetchDepth: 0' "$AP" || fail "the pipeline fetches shallow: the merge commit's parents are needed"
[ "$(grep -c "condition: and(succeededOrFailed(), eq(variables\['SDD_REFS'\], 'ok'))" "$AP")" = 4 ] || fail "each check should run only after the refs step"
awk '/^  - bash: \|$/ { n++; if (n == 1) { f = 1; next } } f && /^    name: refs$/ { exit } f { sub(/^      /, ""); print }' "$AP" > "$TMP_ROOT/refs.sh"
grep -q 'HEAD\^2' "$TMP_ROOT/refs.sh" || fail "could not extract the refs step"
wa="$TMP_ROOT/ap-repo"
git init -q -b main "$wa" && git -C "$wa" -c user.email=t@e -c user.name=t commit -q --allow-empty -m base
git -C "$wa" checkout -q -b pr-head && git -C "$wa" -c user.email=t@e -c user.name=t commit -q --allow-empty -m head
git -C "$wa" checkout -q main && git -C "$wa" -c user.email=t@e -c user.name=t commit -q --allow-empty -m moved
git -C "$wa" -c user.email=t@e -c user.name=t merge -q --no-ff --no-edit pr-head
ap_head="$(git -C "$wa" rev-parse pr-head)"
# Run as the Bash task runs a script: no errexit.
out="$(cd "$wa" && HEAD_SHA="$ap_head" bash "$TMP_ROOT/refs.sh")" || { echo "$out"; fail "refs step failed on a PR merge commit"; }
printf '%s\n' "$out" | grep -qx '##vso\[task.setvariable variable=SDD_REFS\]ok' || { echo "$out"; fail "refs step did not mark the refs ok"; }
printf '%s\n' "$out" | grep -qx "##vso\[task.setvariable variable=SDD_BASE\]$(git -C "$wa" rev-parse HEAD^1)" || { echo "$out"; fail "refs step base"; }
printf '%s\n' "$out" | grep -qx "##vso\[task.setvariable variable=SDD_RESULT\]$(git -C "$wa" rev-parse HEAD)" || fail "refs step result"
refs_step() { cd "$wa" && HEAD_SHA="$1" bash "$TMP_ROOT/refs.sh"; }
expect_exit 1 refs_step "$(git -C "$wa" rev-parse HEAD^1)"
cd "$SCRIPT_DIR"
grep -qx 'archive-mechanical: failure' "$TMP_ROOT/out" || fail "no verdict when the merge isn't the PR's head"
grep -q 'SDD_REFS' "$TMP_ROOT/out" && fail "refs step marked a wrong merge commit ok"
expect_exit 1 refs_step '$(System.PullRequest.SourceCommitId)'
cd "$SCRIPT_DIR"
grep -q 'not a PR build' "$TMP_ROOT/out" || fail "a manual run not explained"
# Text from a PR can't issue an Azure Pipelines logging command.
out="$(SPECS="$T/sdd-specs.mjs" node -e 'import(require("url").pathToFileURL(process.env.SPECS).href).then(m => process.stdout.write(m.clean("##vso[task.complete result=Succeeded] ##VSO[x]")))')"
printf '%s' "$out" | grep -qi '##vso\[' && fail "clean() kept ##vso[: $out"
printf '%s' "$out" | grep -q 'vso\[task.complete result=Succeeded\] .*VSO\[x\]' || fail "clean() lost the text: $out"
pass "the Azure Pipelines template: no token, full history, checks gated on the PR's own merge commit; clean() breaks ##vso["

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
    # Every open form the real parser counts can be ticked, so none is left stuck.
    git -C "$rr" checkout -q -b odd "$rbase"
    printf -- '- [ ] 1.1 a\n- [] 1.2 b\n- [~] 1.3 c\n-[ ] 1.4 d\n- [  ] 1.5 e\r\n' > "$rr/openspec/changes/a-real/tasks.md"
    git -C "$rr" commit -q -am odd-open
    obase="$(git -C "$rr" rev-parse HEAD)"
    printf -- '- [x] 1.1 a\n- [x] 1.2 b\n- [x] 1.3 c\n-[x] 1.4 d\n- [x] 1.5 e\r\n' > "$rr/openspec/changes/a-real/tasks.md"
    git -C "$rr" commit -q -am odd-ticked
    out="$(node "$rr/scripts/sdd/sdd-specs.mjs" requirements -C "$rr" --base "$obase" --result HEAD)" || { echo "$out"; fail "real: ticking every open form"; }
    printf -- '- [x] 1.1 a\n- [x] 1.2 b\n- [x] 1.3 c\n-[x] 1.4 d!\n- [x] 1.5 e\r\n' > "$rr/openspec/changes/a-real/tasks.md"
    git -C "$rr" commit -q -am odd-text
    expect_exit 1 node "$rr/scripts/sdd/sdd-specs.mjs" requirements -C "$rr" --base "$obase" --result HEAD
    grep -qx -- '- a-real: an active change on the base was edited' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "real: a tick with text not refused"; }
    pass "real OpenSpec CLI: pins, check-specs, a stale pin at archive time, and ticking every open form"
fi

# --- sdd-optout.sh: adds the line once, creates CLAUDE.md, refuses what it would sweep up ----
OPT="$SCRIPT_DIR/sdd-optout.sh"
optline="$(cat "$SCRIPT_DIR/optout-line.txt")"
[ -x "$OPT" ] || fail "sdd-optout.sh is not executable"
expect_exit 2 bash "$OPT" --bogus
expect_exit 1 bash "$OPT" --repo "$TMP_ROOT"
o="$(fresh_repo)"
bash "$OPT" --repo "$o" | tail -n 1 | grep -qx 'sdd-optout: done' || fail "opt-out without a CLAUDE.md"
[ "$(cat "$o/CLAUDE.md")" = "$(printf '# CLAUDE.md\n\n%s' "$optline")" ] || { cat "$o/CLAUDE.md"; fail "opt-out created the wrong CLAUDE.md"; }
o2="$(fresh_repo)"
printf '# Mine\n\nNo trailing newline' > "$o2/CLAUDE.md"
expect_exit 1 bash "$OPT" --repo "$o2"
grep -q 'uncommitted changes' "$TMP_ROOT/out" || fail "opt-out did not refuse an uncommitted CLAUDE.md"
git -C "$o2" add CLAUDE.md && git -C "$o2" commit -q -m mine
bash "$OPT" --repo "$o2" >/dev/null
[ "$(cat "$o2/CLAUDE.md")" = "$(printf '# Mine\n\nNo trailing newline\n\n%s' "$optline")" ] || { cat "$o2/CLAUDE.md"; fail "opt-out mangled an existing CLAUDE.md"; }
git -C "$o2" commit -q -am optout
before="$(cat "$o2/CLAUDE.md")"
bash "$OPT" --repo "$o2" | tail -n 1 | grep -qx 'sdd-optout: already opted out' || fail "second opt-out"
[ "$(cat "$o2/CLAUDE.md")" = "$before" ] || fail "second opt-out changed CLAUDE.md"
o4="$(fresh_repo)"
printf "# Mine\n\nThis repository doesn’t use spec-driven development (sdd).\n" > "$o4/CLAUDE.md"
git -C "$o4" add CLAUDE.md && git -C "$o4" commit -q -m curly
bash "$OPT" --repo "$o4" | tail -n 1 | grep -qx 'sdd-optout: done' || fail "opt-out took a look-alike line for the exact one"
[ -z "$(git -C "$o4" log --oneline -1 -- CLAUDE.md | grep -v curly)" ] || fail "opt-out committed"
o3="$(fresh_repo)"
mkdir -p "$o3/.claude" && echo x > "$o3/.claude/sdd-workflow.md"
expect_exit 1 bash "$OPT" --repo "$o3"
grep -q 'set up for sdd' "$TMP_ROOT/out" || fail "opt-out of an sdd repository not refused"
[ ! -e "$o3/CLAUDE.md" ] || fail "a refused opt-out wrote CLAUDE.md"
# A symlinked CLAUDE.md: the target is the file to check, edit and commit.
o5="$(fresh_repo)"
printf '# Agents\n' > "$o5/AGENTS.md" && ln -s AGENTS.md "$o5/CLAUDE.md"
git -C "$o5" add -A && git -C "$o5" commit -q -m agents
echo "wip" >> "$o5/AGENTS.md"
expect_exit 1 bash "$OPT" --repo "$o5"
grep -q 'AGENTS.md has uncommitted changes' "$TMP_ROOT/out" || fail "opt-out missed uncommitted changes in the symlink's target"
git -C "$o5" checkout -q -- AGENTS.md
out="$(bash "$OPT" --repo "$o5")"
printf '%s\n' "$out" | grep -qx 'file: AGENTS.md' || { echo "$out"; fail "opt-out did not name the symlink's target as the file to commit"; }
# Set up for sdd by its import alone, and a fenced quote that isn't an opt-out.
o6="$(fresh_repo)"
printf '# Mine\n\n@.claude/sdd-workflow.md\n' > "$o6/CLAUDE.md" && git -C "$o6" add -A && git -C "$o6" commit -q -m sdd
expect_exit 1 bash "$OPT" --repo "$o6"
grep -q 'imports .claude/sdd-workflow.md' "$TMP_ROOT/out" || fail "opt-out of a CLAUDE.md that imports the workflow not refused"
o7="$(fresh_repo)"
printf '# Mine\n\n```\n%s\n```\n' "$optline" > "$o7/CLAUDE.md" && git -C "$o7" add -A && git -C "$o7" commit -q -m quote
bash "$OPT" --repo "$o7" | tail -n 1 | grep -qx 'sdd-optout: done' || fail "opt-out took a fenced quote for the line"
# An optout-line.txt checked out with CRLF still matches.
crlf="$TMP_ROOT/crlf.$RANDOM" && mkdir -p "$crlf"
cp "$OPT" "$crlf/" && printf '%s\r\n' "$optline" > "$crlf/optout-line.txt"
bash "$crlf/sdd-optout.sh" --repo "$o2" | tail -n 1 | grep -qx 'sdd-optout: already opted out' || fail "a CRLF optout-line.txt did not match"
# A link can't reach outside the repository however it is spelled; only test files are targets.
outside="$TMP_ROOT/outside.$RANDOM.md" && echo keep > "$outside"
for spelling in ".//$outside" "sub/../../$(basename "$outside")" "$outside"; do
    o8="$(fresh_repo)" && mkdir -p "$o8/sub" && ln -s "$spelling" "$o8/CLAUDE.md"
    git -C "$o8" add -A && git -C "$o8" commit -q -m link
    expect_exit 1 bash "$OPT" --repo "$o8"
    [ "$(cat "$outside")" = keep ] || fail "opt-out wrote outside the repository through $spelling"
done
# An absolute link through a symlinked path to the repository still counts as inside it.
o9="$(fresh_repo)" && printf '# Agents\n' > "$o9/AGENTS.md"
ln -s "$o9" "$TMP_ROOT/via.$RANDOM" && via="$(ls -d "$TMP_ROOT"/via.* | tail -n 1)"
ln -s "$via/AGENTS.md" "$o9/CLAUDE.md" && git -C "$o9" add -A && git -C "$o9" commit -q -m via
# Capture first: grep -q exits on its match, and the script's later echo would hit a closed
# pipe and fail the pipeline under pipefail, now and then (seen on macOS).
out="$(bash "$OPT" --repo "$o9")"
printf '%s\n' "$out" | grep -qx 'file: AGENTS.md' || fail "opt-out refused an absolute link through a symlinked path"
# An empty linked file gets just the line, not a CLAUDE.md heading.
o10="$(fresh_repo)" && : > "$o10/AGENTS.md" && ln -s AGENTS.md "$o10/CLAUDE.md"
git -C "$o10" add -A && git -C "$o10" commit -q -m empty
bash "$OPT" --repo "$o10" >/dev/null
[ "$(cat "$o10/AGENTS.md")" = "$optline" ] || { cat "$o10/AGENTS.md"; fail "opt-out headed an empty linked file"; }
# A large file is still read to the end: no early-exit pipe to miss the line.
o11="$(fresh_repo)"
{ printf '# Big\n\n%s\n\n' "$optline"; awk 'BEGIN { for (i = 0; i < 40000; i++) print "filler line " i }'; } > "$o11/CLAUDE.md"
git -C "$o11" add -A && git -C "$o11" commit -q -m big
bash "$OPT" --repo "$o11" | tail -n 1 | grep -qx 'sdd-optout: already opted out' || fail "opt-out missed the line in a large file"
# A ~~~ inside a ``` block doesn't close it: the line after the block is plain text.
o12="$(fresh_repo)"
printf '# Mine\n\n```md\n~~~\n```\n' > "$o12/CLAUDE.md" && git -C "$o12" add -A && git -C "$o12" commit -q -m fences
bash "$OPT" --repo "$o12" >/dev/null && git -C "$o12" commit -q -am optout
bash "$OPT" --repo "$o12" | tail -n 1 | grep -qx 'sdd-optout: already opted out' || fail "opt-out lost track of a fence and added the line twice"
bash "$INIT" --repo "$o12" --no-install >/dev/null
grep -qxF "$optline" "$o12/CLAUDE.md" && fail "init lost track of a fence and kept the opt-out"
# `link/..` resolves the way the kernel does: through the link first.
elsewhere="$TMP_ROOT/elsewhere.$RANDOM" && mkdir -p "$elsewhere/dir" && echo keep > "$elsewhere/AGENTS.md"
o13="$(fresh_repo)" && printf '# Agents\n' > "$o13/AGENTS.md"
ln -s "$elsewhere/dir" "$o13/lnk" && ln -s lnk/../AGENTS.md "$o13/CLAUDE.md"
git -C "$o13" add -A && git -C "$o13" commit -q -m dotdot
expect_exit 1 bash "$OPT" --repo "$o13"
grep -qxF "$optline" "$o13/AGENTS.md" && fail "opt-out edited the repo's AGENTS.md for a link that leaves it"
[ "$(cat "$elsewhere/AGENTS.md")" = keep ] || fail "opt-out wrote outside the repository through link/.."
# CDPATH can't redirect the lookup.
o14="$(fresh_repo)" && mkdir -p "$o14/docs" "$elsewhere/cd/docs" && printf '# Agents\n' > "$o14/docs/AGENTS.md"
ln -s docs/AGENTS.md "$o14/CLAUDE.md" && git -C "$o14" add -A && git -C "$o14" commit -q -m docs
out="$(CDPATH="$elsewhere/cd" bash "$OPT" --repo "$o14")"
printf '%s\n' "$out" | grep -qx 'file: docs/AGENTS.md' || fail "CDPATH redirected the link lookup"
# A trailing slash, a name starting with -, and a glob that matches a committed file.
o15="$(fresh_repo)" && printf '# Agents\n' > "$o15/AGENTS.md" && git -C "$o15" add -A && git -C "$o15" commit -q -m agents
for spelling in "AGENTS.md/" "-/AGENTS.md" "A*.md"; do
    rm -f "$o15/CLAUDE.md" && ln -s -- "$spelling" "$o15/CLAUDE.md"
    mkdir -p "$o15/-" && echo x > "$o15/-/AGENTS.md" && echo x > "$o15/A*.md"
    printf '/-/\n/A*.md\n/CLAUDE.md\n' > "$o15/.git/info/exclude"
    expect_exit 1 bash "$OPT" --repo "$o15"
    tail -n 1 "$TMP_ROOT/out" | grep -qx 'sdd-optout: failed' || { cat "$TMP_ROOT/out"; fail "opt-out through $spelling didn't end with its failed line"; }
done
grep -qxF "$optline" "$o15/AGENTS.md" "$o15/-/AGENTS.md" "$o15/A*.md" && fail "opt-out edited a file through a link it should refuse"
# Fences: 4 spaces of indent is code, not a fence; a backtick info string with a backtick isn't
# a fence; a fence left open at the end is refused.
o16="$(fresh_repo)"
printf '# Mine\n\n    ```\n' > "$o16/CLAUDE.md" && git -C "$o16" add -A && git -C "$o16" commit -q -m indented
bash "$OPT" --repo "$o16" >/dev/null && git -C "$o16" commit -q -am optout
bash "$OPT" --repo "$o16" | tail -n 1 | grep -qx 'sdd-optout: already opted out' || fail "opt-out took an indented code line for a fence"
o17="$(fresh_repo)"
printf '# Mine\n\n```a`b\n' > "$o17/CLAUDE.md" && git -C "$o17" add -A && git -C "$o17" commit -q -m infostring
bash "$OPT" --repo "$o17" >/dev/null && git -C "$o17" commit -q -am optout
bash "$OPT" --repo "$o17" | tail -n 1 | grep -qx 'sdd-optout: already opted out' || fail "opt-out took a backtick info string for a fence"
o18="$(fresh_repo)"
printf '# Mine\n\n```\nopen\n' > "$o18/CLAUDE.md" && git -C "$o18" add -A && git -C "$o18" commit -q -m open
expect_exit 1 bash "$OPT" --repo "$o18"
grep -q 'unclosed code fence' "$TMP_ROOT/out" || fail "opt-out appended after an unclosed fence"
pass "sdd-optout adds the exact line once, follows a link only inside the repository, reads Markdown fences and large files right, and refuses an sdd repository or uncommitted changes"

# --- cloud-setup.sh: sdd, handoff and ci only, always exits 0, updates an existing marketplace ---------
CS="$SCRIPT_DIR/../cloud-setup.sh"
fake="$TMP_ROOT/fakebin"
mkdir -p "$fake"
cat > "$fake/claude" <<'EOF2'
#!/bin/bash
echo "$*" >> "$FAKE_LOG"
case "$*" in
    "plugin marketplace add "*) [ -z "${FAKE_MARKETPLACE_EXISTS:-}" ] || exit 1 ;;
    "plugin install "*) [ -z "${FAKE_INSTALL_FAILS:-}" ] || exit 1 ;;
    "plugin update "*) [ -z "${FAKE_UPDATE_FAILS:-}" ] || exit 1 ;;
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
grep -qx 'plugin install ci@tzander-skills' "$FAKE_LOG" || fail "cloud-setup did not install ci"
[ "$(grep -c '^plugin install ' "$FAKE_LOG")" = 3 ] || fail "cloud-setup installed more than sdd, handoff and ci"
grep -q '=== sdd setup finished' "$TMP_ROOT/cshome/setup-script.log" || fail "cloud-setup wrote no log"
for p in sdd handoff ci; do
    # `plugin install` leaves an installed plugin at its old version, so each is updated too.
    grep -qx "plugin update $p@tzander-skills" "$FAKE_LOG" || { cat "$FAKE_LOG"; fail "cloud-setup did not update $p"; }
done
pass "cloud-setup installs sdd, handoff and ci and nothing else, updates them, and logs it"
md="$TMP_ROOT/cshome/.claude/CLAUDE.md"
[ -f "$md" ] || fail "cloud-setup wrote no ~/.claude/CLAUDE.md"
grep -q 'sdd-workflow.md' "$md" || fail "CLAUDE.md does not point at the sdd workflow"
grep -q 'Never run `/sdd:init` unasked' "$md" || fail "CLAUDE.md does not say to ask before /sdd:init"
grep -qF "$(cat "$SCRIPT_DIR/optout-line.txt")" "$md" || fail "CLAUDE.md does not name the exact opt-out line"
grep -q 'Neither: ask once, at the first change' "$md" || fail "CLAUDE.md does not limit the ask to once"
grep -q '`/sdd:opt-out`' "$md" || fail "CLAUDE.md does not name /sdd:opt-out"
grep -q 'recording decisions as ADRs' "$md" || fail "CLAUDE.md does not point at the ADR rules"
grep -q '`/handoff`' "$md" || fail "CLAUDE.md does not mention /handoff"
grep -q 'passes 300,000 it runs `/handoff:relay`' "$md" || fail "CLAUDE.md does not carry the 300k relay rule"
grep -q '`/ci:minutes <pr>`' "$md" || fail "CLAUDE.md does not say to count CI minutes"
grep -q 'TimZander/ci-recipes' "$md" || fail "CLAUDE.md does not point at ci-recipes"
grep -q 'never run `/ci:init`' "$md" || fail "CLAUDE.md does not say to ask before /ci:init"
pass "cloud-setup writes a CLAUDE.md that points at the workflow, honors an opt-out, asks once before /sdd:init, and carries the relay and CI-minutes rules"

FAKE_MARKETPLACE_EXISTS=1 cs_run
grep -qx 'plugin marketplace update tzander-skills' "$FAKE_LOG" || { cat "$FAKE_LOG"; fail "cloud-setup did not update an existing marketplace"; }
pass "cloud-setup updates a marketplace that is already there"

FAKE_INSTALL_FAILS=1 cs_run
[ "$cs_status" -eq 0 ] || fail "cloud-setup exited $cs_status when the install failed"
printf '%s\n' "$cs_out" | grep -q 'WARNING: the sdd plugin did not install' || fail "failed install not reported"
grep -qx 'plugin install handoff@tzander-skills' "$FAKE_LOG" || fail "a failed sdd install stopped the handoff install"
pass "cloud-setup reports a failed install, still installs the rest, and exits 0"

FAKE_UPDATE_FAILS=1 cs_run
[ "$cs_status" -eq 0 ] || fail "cloud-setup exited $cs_status when an update failed"
printf '%s\n' "$cs_out" | grep -q 'WARNING: the sdd plugin did not update' || fail "failed update not reported"
grep -qx 'plugin update ci@tzander-skills' "$FAKE_LOG" || fail "a failed sdd update stopped the ci update"
pass "cloud-setup reports a failed update, still updates the rest, and exits 0"

echo "all sdd tests passed"
