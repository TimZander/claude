// JSON edits for sdd-init.sh. Adds what is missing and never overwrites a value the repo
// already set: a different value is reported as a warning for the owner to reconcile.
//
//   node sdd-init-json.mjs package  <package.json>  <openspec-version>
//   node sdd-init-json.mjs settings <settings.json> <marketplace-repo>
//
// Prints one line per edit (`added ...`) or conflict (`warning: ...`).
// Exit status: 0 done, 2 usage error, 3 the file is not valid JSON.
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { basename, dirname, resolve } from 'node:path'

const [mode, file, arg] = process.argv.slice(2)
if (!['package', 'settings'].includes(mode) || !file || !arg) {
  console.error('usage: sdd-init-json.mjs package <package.json> <openspec-version>')
  console.error('       sdd-init-json.mjs settings <settings.json> <marketplace-repo>')
  process.exit(2)
}

let data = {}
let raw = ''
if (existsSync(file)) {
  raw = readFileSync(file, 'utf8')
  try {
    data = JSON.parse(raw)
  } catch (error) {
    console.error(`sdd-init: ${file} is not valid JSON: ${error.message}`)
    process.exit(3)
  }
} else if (mode === 'package') {
  data = { name: basename(resolve(dirname(file))).toLowerCase().replace(/[^a-z0-9._-]/g, '-'), private: true }
  console.log(`added ${file}`)
}

// Sets obj[key] = value when absent; reports a conflict when present and different.
function ensure(obj, key, value, label) {
  if (!(key in obj)) {
    obj[key] = value
    console.log(`added ${label}`)
  } else if (JSON.stringify(obj[key]) !== JSON.stringify(value)) {
    console.log(`warning: ${label} is ${JSON.stringify(obj[key])}, kept (sdd expects ${JSON.stringify(value)})`)
  }
}

function section(obj, key) {
  if (typeof obj[key] !== 'object' || obj[key] === null || Array.isArray(obj[key])) {
    obj[key] = {}
  }
  return obj[key]
}

if (mode === 'package') {
  ensure(section(data, 'devDependencies'), '@fission-ai/openspec', arg, 'devDependencies["@fission-ai/openspec"]')
  const scripts = section(data, 'scripts')
  ensure(scripts, 'openspec', 'bash scripts/sdd/openspec.sh', 'scripts.openspec')
  ensure(scripts, 'spec:validate', 'bash scripts/sdd/openspec.sh validate --all --strict', 'scripts["spec:validate"]')
  ensure(scripts, 'spec:check', 'bash scripts/sdd/check-specs.sh', 'scripts["spec:check"]')
  ensure(scripts, 'prepare', 'node scripts/sdd/setup-agent-skills.mjs', 'scripts.prepare')
} else {
  ensure(section(data, 'env'), 'OPENSPEC_TELEMETRY', '0', 'env.OPENSPEC_TELEMETRY')
  ensure(section(data, 'extraKnownMarketplaces'), 'tzander-skills',
    { source: { source: 'github', repo: arg } }, 'extraKnownMarketplaces["tzander-skills"]')
  ensure(section(data, 'enabledPlugins'), 'sdd@tzander-skills', true, 'enabledPlugins["sdd@tzander-skills"]')

  // The SessionStart hook: added once, next to any hooks the repo already has.
  const hooks = section(data, 'hooks')
  if (!Array.isArray(hooks.SessionStart)) {
    hooks.SessionStart = []
  }
  const present = JSON.stringify(hooks.SessionStart).includes('scripts/sdd/session-start.sh')
  if (!present) {
    hooks.SessionStart.push({
      hooks: [{ type: 'command', command: 'bash "$CLAUDE_PROJECT_DIR/scripts/sdd/session-start.sh"' }],
    })
    console.log('added hooks.SessionStart (scripts/sdd/session-start.sh)')
  }
}

const out = JSON.stringify(data, null, 2) + '\n'
if (out !== raw) {
  mkdirSync(dirname(file), { recursive: true })
  writeFileSync(file, out)
}
