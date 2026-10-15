// Installed by the sdd plugin (sdd-init). Re-running sdd-init overwrites this file.
//
// Publishes the sdd-checks verdicts on GitHub, when the repository asks for it in package.json
// (sdd-config.mjs): a commit status per check on the PR's head ("statuses": true), and one PR
// comment of this job's own with the main specs' diff ("specDiffComment", on by default).
// The job log stays the agents' source of the verdicts; this is for people and for branch
// protection.
//
//   node sdd-github.mjs report [--check <name>=<state>]... [--comment <file>]
//
// <state> is a check's verdict as its step printed it (success, failure, not-an-archive-pr,
// no-active-change, disabled), or empty when the step didn't get to print one, which posts
// `error`. Status names are `sdd/<name>`. The comment is created only when --comment's file
// exists and the main-spec-diff verdict isn't no-active-change; otherwise an existing comment of
// this job's own is updated, and no other comment is ever edited.
//
// Environment: GITHUB_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, HEAD_SHA, RUN_URL, and optionally
// GITHUB_API_URL and BOT_LOGIN (default github-actions[bot]).
//
// Never fails the step: a refused or failed call is a `- ` line, and it always exits 0 unless
// the arguments are wrong (2).
import { existsSync, readFileSync, realpathSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { readConfig } from './sdd-config.mjs'

const MARKER = '<!-- sdd-main-spec-diff -->'
const CHECKS = ['spec-checks', 'requirements-through-change', 'main-spec-diff', 'archive-mechanical']
const TIMEOUT_MS = 15_000
const PAGE = 100

/** GitHub's state and a fixed description for each verdict. */
const STATES = {
  success: ['success', 'Passed'],
  failure: ['failure', 'Failed: see the job log'],
  'not-an-archive-pr': ['success', 'Not an archive PR'],
  'no-active-change': ['success', 'No active OpenSpec change'],
  disabled: ['success', 'Turned off in package.json'],
  '': ['error', 'The check did not run: see the job log'],
}

/**
 * @param {{ env: NodeJS.ProcessEnv, fetch: typeof fetch, log: (line: string) => void, config: ReturnType<typeof readConfig> }} io
 * @param {Map<string, string>} checks
 * @param {string | null} commentFile
 */
export async function report(io, checks, commentFile) {
  const { env } = io
  const api = env.GITHUB_API_URL ?? 'https://api.github.com'
  const repo = env.GITHUB_REPOSITORY
  const bot = env.BOT_LOGIN ?? 'github-actions[bot]'
  if (!env.GITHUB_TOKEN || !repo || !env.PR_NUMBER || !env.HEAD_SHA) {
    io.log('- not posting to GitHub: GITHUB_TOKEN, GITHUB_REPOSITORY, PR_NUMBER or HEAD_SHA is not set')
    return
  }
  const headers = {
    authorization: `Bearer ${env.GITHUB_TOKEN}`,
    accept: 'application/vnd.github+json',
    'content-type': 'application/json',
    'x-github-api-version': '2022-11-28',
  }
  const call = async (/** @type {string} */ method, /** @type {string} */ path, /** @type {unknown} */ body) => {
    try {
      const res = await io.fetch(`${api}${path}`, {
        method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(TIMEOUT_MS),
      })
      const text = await res.text()
      let json = null
      try {
        json = text === '' ? null : JSON.parse(text)
      } catch {
        // not JSON: treated as no data
      }
      return { ok: res.ok, status: res.status, json }
    } catch {
      return { ok: false, status: 0, json: null }
    }
  }

  if (io.config.statuses) {
    for (const [name, verdict] of checks) {
      const [state, description] = STATES[/** @type {keyof typeof STATES} */ (verdict)] ?? STATES['']
      const res = await call('POST', `/repos/${repo}/statuses/${env.HEAD_SHA}`, {
        state, context: `sdd/${name}`, description, ...(env.RUN_URL ? { target_url: env.RUN_URL } : {}),
      })
      io.log(res.ok ? `- posted sdd/${name}: ${state}` : `- could not post sdd/${name} (HTTP ${res.status})`)
    }
  }

  if (io.config.specDiffComment && commentFile !== null) {
    if (!existsSync(commentFile)) {
      io.log('- no main-spec diff to post')
      return
    }
    const body = readFileSync(commentFile, 'utf8')
    const create = checks.get('main-spec-diff') !== 'no-active-change'
    const issue = `/repos/${repo}/issues/${env.PR_NUMBER}/comments`
    for (let page = 1; ; page++) {
      const list = await call('GET', `${issue}?per_page=${PAGE}&page=${page}`)
      if (!list.ok || !Array.isArray(list.json)) {
        io.log(`- could not list the PR's comments (HTTP ${list.status})`)
        return
      }
      const own = list.json.find(x => x?.user?.login === bot && typeof x.body === 'string' && x.body.startsWith(MARKER))
      if (own) {
        const res = await call('PATCH', `/repos/${repo}/issues/comments/${own.id}`, { body })
        io.log(res.ok ? '- updated the main-spec diff comment' : `- could not update the comment (HTTP ${res.status})`)
        return
      }
      if (list.json.length < PAGE) {
        break
      }
    }
    if (!create) {
      return
    }
    const res = await call('POST', issue, { body })
    io.log(res.ok ? '- posted the main-spec diff comment' : `- could not post the comment (HTTP ${res.status})`)
  }
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
  const checks = new Map()
  let comment = null
  let ok = args[0] === 'report'
  for (let i = 1; ok && i < args.length; i += 2) {
    const value = args[i + 1]
    if (value === undefined) {
      ok = false
    } else if (args[i] === '--check') {
      const m = /^([a-z-]+)=([a-z-]*)$/.exec(value)
      ok = m !== null && CHECKS.includes(m[1])
      if (m) {
        checks.set(m[1], m[2])
      }
    } else if (args[i] === '--comment') {
      comment = value
    } else {
      ok = false
    }
  }
  if (!ok) {
    console.error('usage: sdd-github.mjs report [--check <name>=<state>]... [--comment <file>]')
    process.exit(2)
  }
  let config
  try {
    config = readConfig()
  } catch (error) {
    console.log(`- not posting to GitHub: ${error instanceof Error ? error.message : error}`)
    process.exit(0)
  }
  await report({ env: process.env, fetch, log: x => console.log(x), config }, checks, comment)
}
