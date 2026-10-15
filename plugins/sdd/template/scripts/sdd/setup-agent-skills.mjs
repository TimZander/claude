// Installed by the sdd plugin (sdd-init). Re-running sdd-init overwrites this file.
// Generates OpenSpec's agent skills and commands from the pinned OpenSpec version, for the
// tools in package.json's "sdd": { "tools": [...] } (default ["claude"]; see sdd-config.mjs).
// Runs as the `prepare` script on `npm install`, and from the SessionStart hook after it
// installs; skipped in CI and when dev dependencies are absent.
// The generated files are gitignored and never edited.
import { spawnSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { readConfig } from './sdd-config.mjs'

const ci = process.env.CI
if (typeof ci === 'string' && ci !== '' && ci !== 'false' && ci !== '0') {
  process.exit(0)
}

const repoRoot = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
const openspecBin = join(repoRoot, 'node_modules', '@fission-ai', 'openspec', 'bin', 'openspec.js')

if (!existsSync(openspecBin)) {
  console.log('OpenSpec is not installed (dev dependencies omitted?); skipped generating agent skills.')
  process.exit(0)
}

let tools
try {
  tools = readConfig(repoRoot).tools.join(',')
} catch (error) {
  console.error(`setup-agent-skills: ${error instanceof Error ? error.message : error}`)
  process.exit(1)
}

const result = spawnSync(
  process.execPath,
  [openspecBin, 'init', '--tools', tools, '--no-animation'],
  {
    stdio: 'inherit',
    shell: false,
    cwd: repoRoot,
    env: { ...process.env, OPENSPEC_TELEMETRY: '0' },
  },
)

if (result.error || result.signal || result.status === null) {
  process.exit(1)
}
process.exit(result.status)
