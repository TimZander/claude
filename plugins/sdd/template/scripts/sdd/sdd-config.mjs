// Installed by the sdd plugin (sdd-init). Re-running sdd-init overwrites this file.
//
// The repository's sdd settings: the `sdd` field of its package.json. Every setting is
// optional; an unknown key or a value of the wrong type is an error, so a typo never silently
// turns a check off.
//
//   "sdd": {
//     "tools": ["claude"],          tools OpenSpec generates skills for (`openspec init --tools`)
//     "changeNames": "default",     "default": [A-Za-z0-9][A-Za-z0-9._-]*
//                                   "lowercase": [a-z0-9][a-z0-9-]*, not starting YYYY-MM-DD-
//     "pins": true,                 every active change holds base-pins.json (see sdd-specs.mjs)
//     "statuses": false,            CI also posts a commit status per check
//     "specDiffComment": true,      CI keeps a PR comment with the main specs' diff
//     "archiveVerdicts": [],        more verdicts /sdd:archive-pr must see as success, each
//                                   { "workflow": ".github/workflows/x.yml", "line": "name" }
//     "autoMerge": true             /sdd:archive-pr merges a mechanical archive PR itself
//   }
//
// The settings always come from the checkout these scripts run from, never from a PR's tree:
// in CI that is the base branch.
//
//   node sdd-config.mjs [--root <dir>] <key>   prints one setting: booleans as true/false,
//                                              tools comma-separated, archiveVerdicts one
//                                              `<workflow>\t<line>` per line
//   node sdd-config.mjs [--root <dir>] --json  prints every setting as JSON
//
// Exit status: 0 done, 2 usage error, 3 invalid settings.
import { existsSync, readFileSync, realpathSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

/** The checkout these scripts belong to: <root>/scripts/sdd/. */
export const TRUSTED_ROOT = dirname(dirname(dirname(fileURLToPath(import.meta.url))))

export const DEFAULTS = Object.freeze({
  tools: ['claude'],
  changeNames: 'default',
  pins: true,
  statuses: false,
  specDiffComment: true,
  archiveVerdicts: [],
  autoMerge: true,
})

const TOOL = /^[a-z0-9][a-z0-9-]*$/
const WORKFLOW = /^\.github\/workflows\/[A-Za-z0-9._-]+\.ya?ml$/
const VERDICT_LINE = /^[A-Za-z0-9][A-Za-z0-9._/-]*$/

export class ConfigError extends Error {}

/**
 * Reads and checks the `sdd` settings of a checkout's package.json, filling in defaults.
 * @param {string} [root]
 * @returns {typeof DEFAULTS}
 */
export function readConfig(root = TRUSTED_ROOT) {
  const file = join(root, 'package.json')
  /** @type {Record<string, unknown>} */
  let raw = {}
  if (existsSync(file)) {
    let pkg
    try {
      pkg = JSON.parse(readFileSync(file, 'utf8'))
    } catch (error) {
      throw new ConfigError(`package.json is not valid JSON: ${error instanceof Error ? error.message : error}`)
    }
    if (pkg !== null && typeof pkg === 'object' && 'sdd' in pkg) {
      if (typeof pkg.sdd !== 'object' || pkg.sdd === null || Array.isArray(pkg.sdd)) {
        throw new ConfigError('package.json "sdd" must be an object')
      }
      raw = pkg.sdd
    }
  }
  const config = { ...DEFAULTS }
  for (const [key, value] of Object.entries(raw)) {
    const bad = (/** @type {string} */ want) => new ConfigError(`package.json sdd.${key} must be ${want}`)
    switch (key) {
      case 'tools':
        if (!Array.isArray(value) || value.length === 0 || !value.every(x => typeof x === 'string' && TOOL.test(x))) {
          throw bad('a non-empty array of tool ids such as "claude"')
        }
        config.tools = [...new Set(value)]
        break
      case 'changeNames':
        if (value !== 'default' && value !== 'lowercase') {
          throw bad('"default" or "lowercase"')
        }
        config.changeNames = value
        break
      case 'pins':
      case 'statuses':
      case 'specDiffComment':
      case 'autoMerge':
        if (typeof value !== 'boolean') {
          throw bad('true or false')
        }
        config[key] = value
        break
      case 'archiveVerdicts':
        if (!Array.isArray(value) || !value.every(x => x !== null && typeof x === 'object'
          && Object.keys(x).sort().join(',') === 'line,workflow'
          && typeof x.workflow === 'string' && WORKFLOW.test(x.workflow)
          && typeof x.line === 'string' && VERDICT_LINE.test(x.line))) {
          throw bad('an array of { "workflow": ".github/workflows/<file>.yml", "line": "<verdict name>" }')
        }
        config.archiveVerdicts = value.map(x => ({ workflow: x.workflow, line: x.line }))
        break
      default:
        throw new ConfigError(`package.json sdd.${key} is not an sdd setting`)
    }
  }
  return config
}

const DATE_PREFIX = /^[0-9]{4}-[0-9]{2}-[0-9]{2}-/

/**
 * Whether a change folder name is safe, and allowed by the repository's rule.
 * @param {string} name
 * @param {'default' | 'lowercase'} rule
 * @returns {boolean}
 */
export function isValidChangeName(name, rule) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name)) {
    return false
  }
  return rule !== 'lowercase' || (/^[a-z0-9][a-z0-9-]*$/.test(name) && !DATE_PREFIX.test(name))
}

/**
 * The change an archive folder the base doesn't have archives, or null if it isn't an archive
 * folder of a valid change name. OpenSpec keeps a change name that already starts with a date
 * as the whole folder name, so a folder equal to an active change on the base is that change.
 * @param {string} folder
 * @param {Set<string>} baseActive
 * @param {'default' | 'lowercase'} rule
 * @returns {string | null}
 */
export function archivedChangeName(folder, baseActive, rule) {
  if (baseActive.has(folder) && isValidChangeName(folder, rule)) {
    return folder
  }
  if (!DATE_PREFIX.test(folder)) {
    return null
  }
  const name = folder.slice(11)
  return isValidChangeName(name, rule) ? name : null
}

function isMain() {
  try {
    return process.argv[1] !== undefined && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href
  } catch {
    return false
  }
}

if (isMain()) {
  const args = process.argv.slice(2)
  let root = TRUSTED_ROOT
  if (args[0] === '--root') {
    if (args.length < 2) {
      args.length = 0
    } else {
      root = args[1]
      args.splice(0, 2)
    }
  }
  if (args.length !== 1 || !(args[0] === '--json' || args[0] in DEFAULTS)) {
    console.error(`usage: sdd-config.mjs [--root <dir>] <${Object.keys(DEFAULTS).join('|')}|--json>`)
    process.exit(2)
  }
  let config
  try {
    config = readConfig(root)
  } catch (error) {
    console.error(`sdd-config: ${error instanceof Error ? error.message : error}`)
    process.exit(3)
  }
  const key = args[0]
  if (key === '--json') {
    console.log(JSON.stringify(config, null, 2))
  } else if (key === 'tools') {
    console.log(config.tools.join(','))
  } else if (key === 'archiveVerdicts') {
    for (const x of config.archiveVerdicts) {
      console.log(`${x.workflow}\t${x.line}`)
    }
  } else {
    console.log(String(config[/** @type {keyof typeof DEFAULTS} */ (key)]))
  }
}
