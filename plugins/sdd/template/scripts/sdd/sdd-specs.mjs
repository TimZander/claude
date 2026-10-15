// Installed by the sdd plugin (sdd-init). Re-running sdd-init overwrites this file.
//
// The spec checks that need to read requirements: base pins, open tasks, requirements that
// change only through a change, and the main specs' diff after archiving. Requirement blocks,
// delta sections and task lines are read with the pinned OpenSpec CLI's own parsers, so they
// mean exactly what `openspec archive` means by them.
//
//   node sdd-specs.mjs pin [-C <dir>] <change>
//       Writes openspec/changes/<change>/base-pins.json in the working tree: for every
//       requirement the change's deltas touch, the SHA-256 of that requirement's block in the
//       main spec now (MODIFIED, REMOVED, a rename's FROM), or null (ADDED, a rename's TO).
//       Fails, writing nothing, when a requirement it modifies, removes or renames isn't there.
//       Format: { "version": 1, "pins": { "<capability>": { "<requirement>": "<hex>" | null } } }
//
//   node sdd-specs.mjs check [-C <repo>] --rev <rev>
//       Every active change at <rev> has complete pins (hashes are not compared). Last line
//       `base-pins: success|failure|disabled`.
//
//   node sdd-specs.mjs gate --dir <checkout> --change <name>
//       May <name> be archived mechanically in <checkout>, as it is now? Its pins must be
//       complete and match the main specs, and its tasks.md must have no unfinished task.
//       Prints a `- ` line per problem; exit 1 if any. Run it right before each archive, in
//       archive order, so a change archived earlier in the same PR counts.
//
//   node sdd-specs.mjs requirements [-C <repo>] --base <rev> --result <rev>
//       Do the main specs change only through a change? Last line
//       `requirements-through-change: success|failure`.
//
//   node sdd-specs.mjs spec-diff [-C <repo>] --base <rev> --result <rev> --out <file>
//       Archives every active change of <result> in a scratch checkout and writes a Markdown
//       comment with the main specs' unified diff to <file>. Last line
//       `main-spec-diff: success|failure|no-active-change`.
//
// Pins can be turned off with "sdd": { "pins": false } in package.json (sdd-config.mjs).
// <rev>s are read as data: the OpenSpec CLI and its parsers always come from --cli-root
// (default: the checkout this script is in). Every line that holds text from the specs starts
// with `- ` and has workflow-command syntax broken, so it can't pass for a verdict.
//
// Exit status: 0 success, 1 failure, 2 usage error, 3 internal error.
import { createHash } from 'node:crypto'
import { execFileSync, spawnSync } from 'node:child_process'
import { cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, relative, sep } from 'node:path'
import { pathToFileURL } from 'node:url'
import { archivedChangeName, isValidChangeName, readConfig, TRUSTED_ROOT } from './sdd-config.mjs'

const SPECS_DIR = 'openspec/specs'
const CHANGES_DIR = 'openspec/changes'
const ARCHIVE_DIR = `${CHANGES_DIR}/archive`
const SYMLINK_MODE = '120000'
const SUBMODULE_MODE = '160000'
const SHA256 = /^[0-9a-f]{64}$/
const MAX_OUTPUT_BYTES = 64 * 1024 * 1024
const CLI_TIMEOUT_MS = 300_000

export class InternalError extends Error {}

// --- output ----------------------------------------------------------------------------------

/**
 * Makes text safe for one log line: no line breaks or tabs, and GitHub's `::` and `##[` workflow
 * command syntax broken.
 * @param {string} text
 * @returns {string}
 */
export function clean(text) {
  return String(text).replace(/[\r\n\t]+/g, ' ').replace(/##\[/g, '#\\u0023[').replace(/::/g, ':\\u003a')
}

/** @param {string} text */
function item(text) {
  console.log(`- ${clean(text)}`)
}

// --- the pinned OpenSpec parsers ---------------------------------------------------------------

/**
 * @typedef {{ name: string, raw: string }} Block
 * @typedef {{
 *   extractRequirementsSection: (content: string) => { bodyBlocks: Block[] },
 *   parseDeltaSpec: (content: string) => { added: Block[], modified: Block[], removed: string[], renamed: { from: string, to: string }[] },
 *   parseTaskLines: (content: string) => { done: boolean }[],
 * }} Parser
 */

/**
 * Loads the parsers of the CLI installed under cliRoot. They aren't public exports, so they are
 * imported by path and probed: a CLI version that moved or reshaped them fails loudly here.
 * @param {string} cliRoot
 * @returns {Promise<Parser>}
 */
export async function loadParser(cliRoot) {
  const dist = join(cliRoot, 'node_modules', '@fission-ai', 'openspec', 'dist')
  if (!existsSync(dist)) {
    throw new InternalError(`OpenSpec is not installed in ${cliRoot}: run \`npm ci\` there first`)
  }
  let blocks, tasks
  try {
    blocks = await import(pathToFileURL(join(dist, 'core', 'parsers', 'requirement-blocks.js')).href)
    tasks = await import(pathToFileURL(join(dist, 'utils', 'task-progress.js')).href)
  } catch (error) {
    throw new InternalError(`cannot load the OpenSpec parsers: ${error instanceof Error ? error.message.split('\n')[0] : error}`)
  }
  /** @type {Parser} */
  const parser = {
    extractRequirementsSection: blocks.extractRequirementsSection,
    parseDeltaSpec: blocks.parseDeltaSpec,
    parseTaskLines: tasks.parseTaskLines,
  }
  let ok = Object.values(parser).every(x => typeof x === 'function')
  if (ok) {
    const main = parser.extractRequirementsSection('## Requirements\n\n### Requirement: X\nx\n').bodyBlocks
    const delta = parser.parseDeltaSpec('## ADDED Requirements\n\n### Requirement: X\nx\n')
    const taskLines = parser.parseTaskLines('- [ ] a\n')
    ok = main?.[0]?.name === 'X' && typeof main[0].raw === 'string'
      && delta?.added?.[0]?.name === 'X' && Array.isArray(delta.modified) && Array.isArray(delta.removed)
      && Array.isArray(delta.renamed) && taskLines?.[0]?.done === false
  }
  if (!ok) {
    throw new InternalError('the pinned OpenSpec CLI\'s parsers changed; this sdd version doesn\'t support it')
  }
  return parser
}

// --- spec text ---------------------------------------------------------------------------------

/**
 * CRLF to LF, trailing whitespace trimmed, runs of blank lines collapsed into one, trailing
 * blank lines dropped (so no final newline).
 * @param {string} text
 * @returns {string}
 */
export function normaliseText(text) {
  /** @type {string[]} */
  const lines = []
  for (const raw of text.replace(/\r\n?/g, '\n').split('\n')) {
    const line = raw.trimEnd()
    if (line === '' && lines.length > 0 && lines[lines.length - 1] === '') {
      continue
    }
    lines.push(line)
  }
  while (lines.length > 0 && lines[lines.length - 1] === '') {
    lines.pop()
  }
  return lines.join('\n')
}

/** @param {string} block */
export function hashBlock(block) {
  return createHash('sha256').update(normaliseText(block), 'utf8').digest('hex')
}

/**
 * A main spec's requirement blocks as OpenSpec reads them: name → normalised text. Of two
 * blocks with one name, the last wins; see duplicateNames.
 * @param {Parser} parser
 * @param {string} text
 * @returns {Map<string, string>}
 */
export function requirementBlocks(parser, text) {
  return new Map(parser.extractRequirementsSection(text).bodyBlocks.map(x => [x.name, normaliseText(x.raw)]))
}

/**
 * @param {Parser} parser
 * @param {string} text
 * @returns {string[]}
 */
export function duplicateNames(parser, text) {
  const seen = new Set()
  const dup = new Set()
  for (const block of parser.extractRequirementsSection(text).bodyBlocks) {
    if (seen.has(block.name)) {
      dup.add(block.name)
    }
    seen.add(block.name)
  }
  return [...dup].sort()
}

/**
 * The longest run of backticks in some text.
 * @param {string} text
 */
function longestBacktickRun(text) {
  return Math.max(0, ...[...text.matchAll(/`+/g)].map(x => x[0].length))
}

/**
 * A fenced code block whose fence is longer than any backtick run inside.
 * @param {string} text
 * @param {string} [info]
 */
export function fenceBlock(text, info = '') {
  const fence = '`'.repeat(Math.max(3, longestBacktickRun(text) + 1))
  return `${fence}${info}\n${text}\n${fence}`
}

/**
 * Untrusted text as a literal inline code span on one line.
 * @param {string} text
 */
export function codeSpan(text) {
  const oneLine = text.replace(/[\r\n]+/g, ' ')
  const ticks = '`'.repeat(longestBacktickRun(oneLine) + 1)
  const pad = oneLine.startsWith('`') || oneLine.endsWith('`') ? ' ' : ''
  return `${ticks}${pad}${oneLine}${pad}${ticks}`
}

// --- trees -------------------------------------------------------------------------------------

/**
 * @param {string} cwd
 * @param {string[]} args
 * @returns {Buffer}
 */
function runGit(cwd, args) {
  return execFileSync('git', args, { cwd, env: childEnv(), maxBuffer: MAX_OUTPUT_BYTES, stdio: ['ignore', 'pipe', 'pipe'] })
}

/** @param {string} cwd @param {string[]} args */
function git(cwd, args) {
  return runGit(cwd, args).toString('utf8')
}

/** The environment for child processes: no GitHub tokens, telemetry and colour off. */
function childEnv() {
  const env = { ...process.env, OPENSPEC_TELEMETRY: '0', NO_COLOR: '1', GIT_LFS_SKIP_SMUDGE: '1' }
  delete env.GITHUB_TOKEN
  delete env.GH_TOKEN
  return env
}

/** The openspec/ tree of one commit (`ref`) or of a directory on disk (`dir`). */
export class Tree {
  /** @param {{ repo?: string, ref?: string, dir?: string }} options */
  constructor(options) {
    this.repo = options.repo
    this.ref = options.ref
    this.dir = options.dir
    /** @type {Map<string, string> | null} path → mode */
    this.entries = null
  }

  /** @returns {Map<string, string>} */
  openspecEntries() {
    if (this.entries !== null) {
      return this.entries
    }
    const entries = new Map()
    if (this.ref !== undefined) {
      const out = git(/** @type {string} */ (this.repo), ['ls-tree', '-r', '-z', '--full-tree', this.ref, '--', 'openspec'])
      for (const line of out.split('\0').filter(x => x !== '')) {
        entries.set(line.slice(line.indexOf('\t') + 1), line.split(' ')[0])
      }
    } else {
      const root = /** @type {string} */ (this.dir)
      const walk = (/** @type {string} */ d) => {
        for (const name of readdirSync(d)) {
          const full = join(d, name)
          const stat = lstatSync(full)
          const path = relative(root, full).split(sep).join('/')
          if (stat.isSymbolicLink()) {
            entries.set(path, SYMLINK_MODE)
          } else if (stat.isDirectory()) {
            walk(full)
          } else {
            entries.set(path, '100644')
          }
        }
      }
      if (existsSync(join(root, 'openspec'))) {
        walk(join(root, 'openspec'))
      }
    }
    this.entries = entries
    return entries
  }

  /** @param {string} prefix @returns {string[]} */
  files(prefix) {
    return [...this.openspecEntries().keys()].filter(x => x === prefix || x.startsWith(`${prefix}/`)).sort()
  }

  /** Symbolic links and submodules under openspec/. */
  specialEntries() {
    return [...this.openspecEntries()].filter(([, m]) => m === SYMLINK_MODE || m === SUBMODULE_MODE).map(([p]) => p).sort()
  }

  /** @param {string} path @returns {string | null} */
  text(path) {
    const mode = this.openspecEntries().get(path)
    if (mode === undefined || mode === SYMLINK_MODE || mode === SUBMODULE_MODE) {
      return null
    }
    if (this.ref !== undefined) {
      return runGit(/** @type {string} */ (this.repo), ['cat-file', 'blob', `${this.ref}:${path}`]).toString('utf8')
    }
    return readFileSync(join(/** @type {string} */ (this.dir), path), 'utf8')
  }

  /** @param {string} capability */
  mainSpec(capability) {
    return this.text(`${SPECS_DIR}/${capability}/spec.md`)
  }

  /** Folders directly under dir that hold at least one file. @param {string} dir */
  folders(dir) {
    const names = new Set()
    for (const path of this.files(dir)) {
      const parts = path.slice(dir.length + 1).split('/')
      if (parts.length > 1) {
        names.add(parts[0])
      }
    }
    return [...names].sort()
  }

  /** Active change folders, in archive order (ascending byte order). */
  activeChanges() {
    return this.folders(CHANGES_DIR).filter(x => x !== 'archive').sort(byteOrder)
  }

  archiveFolders() {
    return this.folders(ARCHIVE_DIR)
  }

  /**
   * A change's delta specs: capability → text.
   * @param {string} change
   * @returns {Map<string, string>}
   */
  deltas(change) {
    const deltas = new Map()
    const prefix = `${CHANGES_DIR}/${change}/specs/`
    for (const path of this.files(`${CHANGES_DIR}/${change}/specs`)) {
      const capability = path.slice(prefix.length, -'/spec.md'.length)
      const text = path.endsWith('/spec.md') && capability !== '' ? this.text(path) : null
      if (text !== null) {
        deltas.set(capability, text)
      }
    }
    return deltas
  }

  /**
   * @param {string} change
   * @returns {{ status: 'missing' } | { status: 'invalid' } | { status: 'ok', value: unknown }}
   */
  pins(change) {
    const text = this.text(`${CHANGES_DIR}/${change}/base-pins.json`)
    if (text === null) {
      return { status: 'missing' }
    }
    try {
      return { status: 'ok', value: JSON.parse(text) }
    } catch {
      return { status: 'invalid' }
    }
  }
}

/** @param {string} a @param {string} b */
function byteOrder(a, b) {
  return Buffer.compare(Buffer.from(a), Buffer.from(b))
}

// --- pins --------------------------------------------------------------------------------------

/**
 * The requirements a delta touches. `pinned` is true when the pin records the current hash
 * (MODIFIED, REMOVED, a rename's FROM) and false when it records null (ADDED, a rename's TO).
 * OpenSpec applies renames before modifications, so a MODIFIED entry naming a rename's TO
 * modifies the renamed requirement, which the FROM pin covers; it adds no key.
 * @param {Parser} parser
 * @param {string} delta
 * @returns {{ name: string, pinned: boolean }[]}
 */
export function deltaKeys(parser, delta) {
  const plan = parser.parseDeltaSpec(delta)
  const renamedTo = new Set(plan.renamed.map(x => x.to))
  return [
    ...plan.added.map(x => ({ name: x.name, pinned: false })),
    ...plan.modified.filter(x => !renamedTo.has(x.name)).map(x => ({ name: x.name, pinned: true })),
    ...plan.removed.map(x => ({ name: x, pinned: true })),
    ...plan.renamed.flatMap(x => [{ name: x.from, pinned: true }, { name: x.to, pinned: false }]),
  ]
}

/**
 * @param {Parser} parser
 * @param {Map<string, string>} deltas
 * @param {(capability: string) => string | null} mainSpec
 */
export function computePins(parser, deltas, mainSpec) {
  /** @type {Record<string, Record<string, string | null>>} */
  const pins = {}
  /** @type {string[]} */
  const missing = []
  for (const [capability, delta] of deltas) {
    const main = mainSpec(capability)
    const blocks = main === null ? new Map() : requirementBlocks(parser, main)
    /** @type {Record<string, string | null>} */
    const entries = {}
    for (const key of deltaKeys(parser, delta)) {
      const block = blocks.get(key.name)
      if (key.pinned && block === undefined) {
        missing.push(`${capability} / ${key.name}`)
      }
      entries[key.name] = key.pinned && block !== undefined ? hashBlock(block) : null
    }
    pins[capability] = entries
  }
  return { pins: { version: 1, pins }, missing }
}

/** @param {unknown} x @returns {x is Record<string, unknown>} */
function isObject(x) {
  return typeof x === 'object' && x !== null && !Array.isArray(x)
}

/**
 * Problems with a change's pins file: missing, unreadable, or not covering exactly its deltas'
 * requirements. Hashes are not compared.
 * @param {Parser} parser
 * @param {ReturnType<Tree['pins']>} read
 * @param {Map<string, string>} deltas
 * @returns {string[]}
 */
export function pinProblems(parser, read, deltas) {
  if (read.status === 'missing') {
    return ['no base-pins.json']
  }
  if (read.status === 'invalid') {
    return ['base-pins.json is not valid JSON']
  }
  const file = read.value
  if (!isObject(file) || Object.keys(file).sort().join(',') !== 'pins,version' || file.version !== 1 || !isObject(file.pins)) {
    return ['base-pins.json is not { "version": 1, "pins": { ... } }']
  }
  const pins = file.pins
  const problems = []
  for (const capability of new Set([...deltas.keys(), ...Object.keys(pins)])) {
    const raw = Object.hasOwn(pins, capability) ? pins[capability] : {}
    if (!isObject(raw)) {
      problems.push(`${capability}: pins are not an object`)
      continue
    }
    const delta = deltas.get(capability)
    const expected = new Map((delta === undefined ? [] : deltaKeys(parser, delta)).map(x => [x.name, x.pinned]))
    for (const [name, pinned] of expected) {
      if (!Object.hasOwn(raw, name)) {
        problems.push(`${capability} / ${name}: not pinned`)
        continue
      }
      const value = raw[name]
      if (pinned && !(typeof value === 'string' && SHA256.test(value))) {
        problems.push(`${capability} / ${name}: pin is not a SHA-256`)
      }
      if (!pinned && value !== null) {
        problems.push(`${capability} / ${name}: an added or renamed-to requirement is pinned as null`)
      }
    }
    for (const name of Object.keys(raw)) {
      if (!expected.has(name)) {
        problems.push(`${capability} / ${name}: pinned but not in the deltas`)
      }
    }
  }
  return problems
}

/**
 * Pins that don't match the main specs. Call only on complete pins.
 * @param {Parser} parser
 * @param {{ pins: Record<string, Record<string, string | null>> }} file
 * @param {(capability: string) => string | null} mainSpec
 * @returns {string[]} `capability / requirement`
 */
export function stalePins(parser, file, mainSpec) {
  const stale = []
  for (const [capability, entries] of Object.entries(file.pins)) {
    const main = mainSpec(capability)
    const blocks = main === null ? new Map() : requirementBlocks(parser, main)
    for (const [name, pin] of Object.entries(entries)) {
      const block = blocks.get(name)
      if ((block === undefined ? null : hashBlock(block)) !== pin) {
        stale.push(`${capability} / ${name}`)
      }
    }
  }
  return stale
}

/**
 * Problems with a change's pins against a tree's main specs: incomplete, or stale.
 * @param {Parser} parser
 * @param {Tree} changeTree where the change is
 * @param {Tree} specTree whose main specs the pins must match
 * @param {string} change
 * @param {string} staleAdvice what to do about a stale pin
 */
function pinsAgainst(parser, changeTree, specTree, change, staleAdvice) {
  const read = changeTree.pins(change)
  const problems = pinProblems(parser, read, changeTree.deltas(change))
  if (problems.length > 0 || read.status !== 'ok') {
    return problems.map(x => `${change}: ${x}; run \`npm run spec:pin -- ${change}\``)
  }
  const file = /** @type {{ pins: Record<string, Record<string, string | null>> }} */ (read.value)
  return stalePins(parser, file, x => specTree.mainSpec(x))
    .map(x => `${change}: ${x} changed since the delta was written; ${staleAdvice}`)
}

/**
 * Requirements a change's deltas touch, as `capability / name`.
 * @param {Parser} parser
 * @param {Map<string, string>} deltas
 */
function touched(parser, deltas) {
  const keys = new Set()
  for (const [capability, delta] of deltas) {
    for (const key of deltaKeys(parser, delta)) {
      keys.add(`${capability} / ${key.name}`)
    }
  }
  return keys
}

/**
 * Unfinished tasks in a change's tasks.md, counted as OpenSpec counts them.
 * @param {Parser} parser
 * @param {Tree} tree
 * @param {string} change
 */
function openTasks(parser, tree, change) {
  const text = tree.text(`${CHANGES_DIR}/${change}/tasks.md`)
  return text === null ? 0 : parser.parseTaskLines(text.replace(/\r\n?/g, '\n')).filter(x => !x.done).length
}

// --- running the CLI ---------------------------------------------------------------------------

/**
 * Runs the OpenSpec CLI installed under cliRoot in cwd.
 * @param {string} cliRoot
 * @param {string} cwd
 * @param {string[]} args
 */
function openspec(cliRoot, cwd, args) {
  const bin = join(cliRoot, 'node_modules', '@fission-ai', 'openspec', 'bin', 'openspec.js')
  if (!existsSync(bin)) {
    throw new InternalError(`OpenSpec is not installed in ${cliRoot}: run \`npm ci\` there first`)
  }
  const run = spawnSync(process.execPath, [bin, ...args], {
    cwd, env: childEnv(), encoding: 'utf8', shell: false, timeout: CLI_TIMEOUT_MS, maxBuffer: MAX_OUTPUT_BYTES,
  })
  if (run.error || run.signal || run.status === null) {
    throw new InternalError(`the OpenSpec CLI could not run: ${run.error ? run.error.message : `killed by ${run.signal}`}`)
  }
  return { ok: run.status === 0, output: `${run.stdout ?? ''}${run.stderr ?? ''}` }
}

/**
 * Runs fn with a detached worktree of ref, and always removes it.
 * @template T
 * @param {string} repo
 * @param {string} ref
 * @param {(dir: string) => T} fn
 * @returns {T}
 */
function withWorktree(repo, ref, fn) {
  const parent = mkdtempSync(join(tmpdir(), 'sdd-specs-'))
  const dir = join(parent, 'tree')
  try {
    git(repo, ['-c', 'core.hooksPath=/dev/null', 'worktree', 'add', '--detach', '--quiet', dir, ref])
    return fn(dir)
  } finally {
    try {
      git(repo, ['worktree', 'remove', '--force', dir])
    } catch {
      // `worktree add` may have failed; prune below cleans up either way.
    }
    rmSync(parent, { recursive: true, force: true })
    try {
      git(repo, ['worktree', 'prune'])
    } catch {
      // housekeeping only
    }
  }
}

// --- commands ----------------------------------------------------------------------------------

/**
 * @typedef {{ repo: string, cliRoot: string, config: ReturnType<typeof readConfig>, parser: () => Promise<Parser> }} Env
 */

/** @param {string} repo @param {string} rev */
function commit(repo, rev) {
  try {
    return git(repo, ['rev-parse', '--verify', '--quiet', `${rev}^{commit}`]).trim()
  } catch {
    throw new InternalError(`${rev} is not a commit`)
  }
}

/**
 * @param {Env} env
 * @param {string} change
 */
async function cmdPin(env, change) {
  const rule = env.config.changeNames
  if (!isValidChangeName(change, rule)) {
    console.error(`sdd-specs: not a valid change name: ${JSON.stringify(change)}`)
    return 1
  }
  const tree = new Tree({ dir: env.repo })
  if (!tree.activeChanges().includes(change)) {
    console.error(`sdd-specs: no active change ${change} in ${CHANGES_DIR}/`)
    return 1
  }
  const parser = await env.parser()
  const { pins, missing } = computePins(parser, tree.deltas(change), x => tree.mainSpec(x))
  if (missing.length > 0) {
    console.error('sdd-specs: not pinned: these requirements are modified, removed or renamed but are not in the main specs:')
    for (const x of missing) {
      console.error(`  - ${x}`)
    }
    return 1
  }
  const file = `${CHANGES_DIR}/${change}/base-pins.json`
  writeFileSync(join(env.repo, file), `${JSON.stringify(pins, null, 2)}\n`)
  const count = Object.values(pins.pins).reduce((n, x) => n + Object.keys(x).length, 0)
  console.log(`Pinned ${count} requirement${count === 1 ? '' : 's'} in ${file}.`)
  return 0
}

/**
 * @param {Env} env
 * @param {string} rev
 */
async function cmdCheck(env, rev) {
  if (!env.config.pins) {
    console.log('base-pins: disabled')
    return 0
  }
  const tree = new Tree({ repo: env.repo, ref: commit(env.repo, rev) })
  const parser = await env.parser()
  const problems = []
  for (const change of tree.activeChanges()) {
    if (!isValidChangeName(change, env.config.changeNames)) {
      continue // reported by sdd-archive.sh active, before any command runs with it
    }
    const read = tree.pins(change)
    problems.push(...pinProblems(parser, read, tree.deltas(change)).map(x => `${change}: ${x}; run \`npm run spec:pin -- ${change}\``))
  }
  problems.forEach(item)
  console.log(`base-pins: ${problems.length === 0 ? 'success' : 'failure'}`)
  return problems.length === 0 ? 0 : 1
}

/**
 * @param {Env} env
 * @param {string} dir
 * @param {string} change
 */
async function cmdGate(env, dir, change) {
  if (!isValidChangeName(change, env.config.changeNames)) {
    throw new InternalError('not a valid change name')
  }
  const tree = new Tree({ dir })
  const parser = await env.parser()
  const problems = []
  if (env.config.pins) {
    problems.push(...pinsAgainst(parser, tree, tree, change, 'merge the newer text into the delta, re-pin, and have the archive reviewed'))
  }
  const open = openTasks(parser, tree, change)
  if (open > 0) {
    problems.push(`${change}: ${open} unfinished task${open === 1 ? '' : 's'} in tasks.md`)
  }
  problems.forEach(item)
  return problems.length === 0 ? 0 : 1
}

/**
 * The checks' shared preamble: both trees, the changed files, unsafe content, new archives.
 * @param {Env} env
 * @param {string} baseRev
 * @param {string} resultRev
 */
function loadPair(env, baseRev, resultRev) {
  const baseSha = commit(env.repo, baseRev)
  const resultSha = commit(env.repo, resultRev)
  const base = new Tree({ repo: env.repo, ref: baseSha })
  const result = new Tree({ repo: env.repo, ref: resultSha })
  const parts = git(env.repo, ['diff', '--name-only', '--no-renames', '-z', baseSha, resultSha]).split('\0').filter(x => x !== '')
  const baseActive = new Set(base.activeChanges())
  const rule = env.config.changeNames
  const unsafe = result.specialEntries().map(x => `symbolic link or submodule: ${x}`)
  for (const name of result.activeChanges().filter(x => !isValidChangeName(x, rule))) {
    unsafe.push(`not a valid change name: ${name}`)
  }
  const existing = new Set(base.archiveFolders())
  /** @type {{ folder: string, name: string }[]} */
  const archives = []
  for (const folder of result.archiveFolders().filter(x => !existing.has(x))) {
    const name = archivedChangeName(folder, baseActive, rule)
    if (name === null) {
      unsafe.push(`not a dated archive folder of a valid change name: ${folder}`)
    } else {
      archives.push({ folder, name })
    }
  }
  return { baseSha, resultSha, base, result, files: parts, baseActive, archives, existing, unsafe }
}

const MAIN_SPEC = /^openspec\/specs\/(.+)\/spec\.md$/

/**
 * @param {Env} env
 * @param {string} baseRev
 * @param {string} resultRev
 */
async function cmdRequirements(env, baseRev, resultRev) {
  const verdict = (/** @type {string[]} */ items) => {
    items.forEach(item)
    console.log(`requirements-through-change: ${items.length === 0 ? 'success' : 'failure'}`)
    return items.length === 0 ? 0 : 1
  }
  const p = loadPair(env, baseRev, resultRev)
  if (!p.files.some(x => x.startsWith('openspec/')) && p.baseActive.size === 0) {
    return verdict([])
  }
  if (p.unsafe.length > 0) {
    return verdict(p.unsafe)
  }
  const parser = await env.parser()
  const items = []

  // Comparing blocks keeps one block per name, so a duplicate could hide an edit.
  for (const path of p.files) {
    const match = MAIN_SPEC.exec(path)
    const text = match === null ? null : p.result.text(path)
    if (match !== null && text !== null) {
      for (const name of duplicateNames(parser, text)) {
        items.push(`${match[1]} / ${name}: duplicated requirement name`)
      }
    }
  }

  for (const path of p.files.filter(x => x.startsWith(`${ARCHIVE_DIR}/`))) {
    if (p.existing.has(path.slice(ARCHIVE_DIR.length + 1).split('/')[0])) {
      items.push(`${path}: archived history edited`)
    }
  }

  const genuineArchive = p.archives.length > 0 && p.archives.every(x => p.baseActive.has(x.name))
  if (!genuineArchive) {
    for (const path of p.files) {
      const match = MAIN_SPEC.exec(path)
      if (match === null) {
        continue
      }
      const a = requirementBlocks(parser, p.base.text(path) ?? '')
      const b = requirementBlocks(parser, p.result.text(path) ?? '')
      for (const name of [...b.keys()].filter(x => !a.has(x))) {
        items.push(`${match[1]} / ${name}: added without a change`)
      }
      for (const name of [...a.keys()].filter(x => !b.has(x))) {
        items.push(`${match[1]} / ${name}: removed without a change`)
      }
      for (const name of [...b.keys()].filter(x => a.has(x) && a.get(x) !== b.get(x))) {
        items.push(`${match[1]} / ${name}: edited without a change`)
      }
    }
  }

  const archived = new Set(p.archives.map(x => x.name))
  const resultActive = new Set(p.result.activeChanges())
  for (const name of p.baseActive) {
    if (!resultActive.has(name)) {
      if (!archived.has(name)) {
        items.push(`${name}: deleted instead of archived`)
      }
    } else if (p.files.some(x => x.startsWith(`${CHANGES_DIR}/${name}/`))) {
      items.push(`${name}: an active change on the base was edited`)
    }
  }

  if (env.config.pins) {
    for (const name of [...resultActive].filter(x => !p.baseActive.has(x))) {
      items.push(...pinsAgainst(parser, p.result, p.base, name, `update the delta, then run \`npm run spec:pin -- ${name}\``))
    }
  }
  return verdict(items)
}

/** Longest diff or CLI output shown in the comment, in characters. */
export const MAX_OUTPUT_CHARS = 60000
/** Longest comment body, in characters; GitHub's limit is 65,536. */
export const MAX_COMMENT_CHARS = 65000
export const DIFF_MARKER = '<!-- sdd-main-spec-diff -->'
const HEADER = `${DIFF_MARKER}\n### Main specs after archiving`
const MAX_NAMES = 50
const MAX_NAME_CHARS = 200

/** @param {string[]} names */
function listNames(names) {
  const shorten = (/** @type {string} */ x) => x.length <= MAX_NAME_CHARS ? x : `${x.slice(0, MAX_NAME_CHARS - 1)}…`
  const shown = names.slice(0, MAX_NAMES).map(x => codeSpan(shorten(x))).join(', ')
  return names.length > MAX_NAMES ? `${shown} and ${names.length - MAX_NAMES} more` : shown
}

/**
 * @typedef {{ fromPr: string[], onBase: string[], shared: string[], diff: string | null, error: { change: string, output: string } | null }} DiffInput
 */

/**
 * The comment body, cut so it stays within MAX_COMMENT_CHARS.
 * @param {DiffInput} input
 */
export function diffComment(input) {
  let limit = MAX_OUTPUT_CHARS
  for (;;) {
    const body = assembleComment(input, limit)
    const overflow = body.length - MAX_COMMENT_CHARS
    if (overflow <= 0 || limit === 0) {
      return body
    }
    limit = Math.max(0, limit - overflow)
  }
}

/** @param {DiffInput} input @param {number} limit */
function assembleComment(input, limit) {
  const cut = (/** @type {string} */ text) => text.length <= limit
    ? { text, note: null }
    : { text: text.slice(0, limit), note: `*Truncated at ${limit.toLocaleString('en-US')} characters.*` }
  const parts = [HEADER, '']
  if (input.fromPr.length > 0) {
    parts.push(`- **From this PR:** ${listNames(input.fromPr)}`)
  }
  if (input.onBase.length > 0) {
    parts.push(`- **Already on the base:** ${listNames(input.onBase)}`, '')
    parts.push('> ⚠️ The base already has active changes. Archive them in their own PR (`/sdd:archive-pr`) before new work.')
    if (input.shared.length > 0) {
      parts.push(`> They touch the same requirements as this PR: ${listNames(input.shared)}.`)
    }
  }
  parts.push('')
  if (input.error !== null) {
    parts.push(`**Archiving ${codeSpan(input.error.change)} failed**, so no diff is shown.`)
    const out = cut(input.error.output.trim())
    parts.push('', fenceBlock(out.text))
    if (out.note !== null) {
      parts.push('', out.note)
    }
    return parts.join('\n')
  }
  const diff = (input.diff ?? '').replace(/\n$/, '')
  if (diff.trim() === '') {
    parts.push('Archiving changes no main spec.')
    return parts.join('\n')
  }
  const shown = cut(diff)
  parts.push(fenceBlock(shown.text, 'diff'))
  if (shown.note !== null) {
    parts.push('', shown.note)
  }
  return parts.join('\n')
}

export function noActiveChangeComment() {
  return `${HEADER}\n\nThis PR has no active OpenSpec change.`
}

/**
 * A unified diff of <parent>/before and <parent>/after, labelled as openspec/specs.
 * @param {string} parent
 */
function diffFolders(parent) {
  let out
  try {
    out = git(parent, ['-c', 'diff.noprefix=false', '-c', 'diff.mnemonicPrefix=false', 'diff', '--no-index', '--no-color',
      '--no-renames', '--no-ext-diff', '--no-textconv', '--', 'before', 'after'])
  } catch (error) {
    const failed = /** @type {{ status?: number, stdout?: Buffer }} */ (error)
    if (failed.status !== 1) {
      throw new InternalError('git diff failed')
    }
    out = failed.stdout?.toString('utf8') ?? ''
  }
  return out.split('\n').map(x => /^(diff --git|---|\+\+\+) /.test(x)
    ? x.replace(/\b([ab])\/(?:before|after)\//g, '$1/openspec/specs/')
    : x).join('\n')
}

/**
 * @param {Env} env
 * @param {string} baseRev
 * @param {string} resultRev
 * @param {string} out
 */
async function cmdSpecDiff(env, baseRev, resultRev, out) {
  const p = loadPair(env, baseRev, resultRev)
  const done = (/** @type {string} */ state, /** @type {string} */ body, /** @type {string[]} */ items = []) => {
    writeFileSync(out, `${body}\n`)
    items.forEach(item)
    console.log(`main-spec-diff: ${state}`)
    return state === 'failure' ? 1 : 0
  }
  if (p.unsafe.length > 0) {
    return done('failure', `${HEADER}\n\nThis PR has unsafe OpenSpec content, so no diff is shown.`, p.unsafe)
  }
  if (git(env.repo, ['ls-tree', '--name-only', p.resultSha, 'node_modules']).trim() !== '') {
    return done('failure', `${HEADER}\n\nThis PR tracks \`node_modules/\`, so no diff is shown.`, ['the result tracks node_modules/'])
  }
  const active = p.result.activeChanges()
  if (active.length === 0) {
    return done('no-active-change', noActiveChangeComment())
  }
  const parser = await env.parser()
  const fromPr = active.filter(x => !p.baseActive.has(x))
  const onBase = active.filter(x => p.baseActive.has(x))
  const prTouched = new Set(fromPr.flatMap(x => [...touched(parser, p.result.deltas(x))]))
  const shared = [...new Set(onBase.flatMap(x => [...touched(parser, p.result.deltas(x))]))].filter(x => prTouched.has(x)).sort()

  const scratch = mkdtempSync(join(tmpdir(), 'sdd-diff-'))
  try {
    return withWorktree(env.repo, p.resultSha, dir => {
      const specs = join(dir, 'openspec', 'specs')
      const copySpecs = (/** @type {string} */ side) => existsSync(specs)
        ? cpSync(specs, join(scratch, side), { recursive: true })
        : mkdirSync(join(scratch, side), { recursive: true })
      copySpecs('before')
      for (const name of active) {
        const run = openspec(env.cliRoot, dir, ['archive', name, '--yes'])
        if (!run.ok) {
          return done('failure', diffComment({ fromPr, onBase, shared, diff: null, error: { change: name, output: run.output } }),
            [`\`openspec archive ${name}\` failed; the PR comment shows why`])
        }
      }
      copySpecs('after')
      return done('success', diffComment({ fromPr, onBase, shared, diff: diffFolders(scratch), error: null }))
    })
  } finally {
    rmSync(scratch, { recursive: true, force: true })
  }
}

// --- main --------------------------------------------------------------------------------------

const USAGE = `usage: sdd-specs.mjs pin [-C <dir>] <change>
       sdd-specs.mjs check [-C <repo>] --rev <rev>
       sdd-specs.mjs gate --dir <checkout> --change <name>
       sdd-specs.mjs requirements [-C <repo>] --base <rev> --result <rev>
       sdd-specs.mjs spec-diff [-C <repo>] --base <rev> --result <rev> --out <file>
options for every command: --cli-root <dir> (the checkout whose node_modules holds OpenSpec)`

/**
 * @param {string[]} argv
 * @returns {Promise<number>}
 */
export async function main(argv) {
  const [command, ...rest] = argv
  /** @type {Record<string, string>} */
  const opts = {}
  const positional = []
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i]
    if (['-C', '--rev', '--dir', '--change', '--base', '--result', '--out', '--cli-root'].includes(a)) {
      if (i + 1 >= rest.length) {
        return usage()
      }
      opts[a] = rest[++i]
    } else if (a.startsWith('-')) {
      return usage()
    } else {
      positional.push(a)
    }
  }
  const verdictName = { check: 'base-pins', requirements: 'requirements-through-change', 'spec-diff': 'main-spec-diff' }[command]
  try {
    const config = readConfig()
    let repo = opts['-C'] ?? '.'
    if (command !== 'gate') {
      try {
        repo = git(repo, ['rev-parse', '--show-toplevel']).trim()
      } catch {
        throw new InternalError(`${repo} is not a git repository`)
      }
    }
    /** @type {Promise<Parser> | null} */
    let loaded = null
    const cliRoot = opts['--cli-root'] ?? TRUSTED_ROOT
    /** @type {Env} */
    const env = { repo, cliRoot, config, parser: () => (loaded ??= loadParser(cliRoot)) }
    switch (command) {
      case 'pin':
        return positional.length === 1 ? await cmdPin(env, positional[0]) : usage()
      case 'check':
        return positional.length === 0 && opts['--rev'] ? await cmdCheck(env, opts['--rev']) : usage()
      case 'gate':
        return positional.length === 0 && opts['--dir'] && opts['--change'] ? await cmdGate(env, opts['--dir'], opts['--change']) : usage()
      case 'requirements':
        return positional.length === 0 && opts['--base'] && opts['--result'] ? await cmdRequirements(env, opts['--base'], opts['--result']) : usage()
      case 'spec-diff':
        return positional.length === 0 && opts['--base'] && opts['--result'] && opts['--out']
          ? await cmdSpecDiff(env, opts['--base'], opts['--result'], opts['--out'])
          : usage()
      default:
        return usage()
    }
  } catch (error) {
    const message = error instanceof Error ? error.message.split('\n')[0] : String(error)
    console.error(`sdd-specs: ${message}`)
    if (verdictName) {
      item(`reason: ${message}`)
      console.log(`${verdictName}: failure`)
    }
    return 3
  }
}

function usage() {
  console.error(USAGE)
  return 2
}

function isMain() {
  try {
    return process.argv[1] !== undefined && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href
  } catch {
    return false
  }
}

if (isMain()) {
  process.exitCode = await main(process.argv.slice(2))
}
