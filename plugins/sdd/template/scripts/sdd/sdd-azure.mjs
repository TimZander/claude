// Installed by the sdd plugin (sdd-init). Re-running sdd-init overwrites this file.
//
// Azure DevOps helpers for /sdd:archive-pr. They decide; they never call Azure DevOps. The skill
// fetches with `az` and pipes the JSON in, so every rule here is testable offline.
//
//   node sdd-azure.mjs remote [<url>]
//       The organization URL, project and repository of an Azure Repos remote (default: the
//       `origin` of the current directory's repository), as JSON. Exit 1 when it isn't one.
//
//   node sdd-azure.mjs pr --default <branch> [<file>|-]
//       Checks a PR as `az repos pr show -o json` prints it: active, not a draft, not from a fork,
//       from a branch of this repository into the default branch, and its merge computed without
//       conflicts. Prints `head=<sha>` and `source=<ref>`, or a `- ` line per problem. Exit 1 on
//       any problem.
//
//   node sdd-azure.mjs policies [<file>|-]
//       Reads the PR's policy evaluations (`az repos pr policy list -o json`) and prints a `- `
//       line for each blocking policy that isn't met, then `policies=<state>`:
//         none       no policy evaluations: Azure DevOps still checks a completion itself
//         approved   every enabled blocking policy is approved or not applicable
//         pending    none failed, but one is still queued or running: wait and read again
//         reviewers  the only unmet blocking policies are "Minimum number of reviewers"
//         blocked    any other blocking policy failed or isn't met (a failed build, required
//                    reviewers, linked work items, comments, a status policy)
//       Every evaluation must carry a boolean `configuration.isBlocking` (exit 3 otherwise), so
//       a field missing from the input never makes a policy count as non-blocking.
//       Exit 0 for approved or none, 1 otherwise.
//
//   node sdd-azure.mjs complete-body --commit <sha> --pr <file>|- --policies <file>|-
//                                    [--bypass-reviewers] [--message <text>]
//       Prints the body of the PATCH that completes the PR, pinned to <sha>
//       (`lastMergeSourceCommit`), the source commit Azure DevOps is asked to complete. A push
//       after verification should make completion fail; that rests on Azure DevOps' behavior,
//       which no test here exercises, so confirm the completed commit afterwards. The merge
//       strategy is named: the first of noFastForward, rebaseMerge, squash, rebase that every
//       "Require a merge strategy" policy allows. Refuses (exit 1, a `- not completing:` line)
//       unless the repository is on Azure DevOps, `autoMerge` is on, the PR's head is still
//       <sha>, and the policies are `approved` or `none`. The one exception: policies
//       `reviewers`, --bypass-reviewers given, `archiveBypassReviewers` true, and no reviewer
//       voted Reject or Waiting for author; then the body bypasses policy with a reason.
//       Settings come from this checkout's package.json (sdd-config.mjs), never a PR's.
//
// Exit status: 0 done, 1 refused or not met, 2 usage error, 3 bad input.
import { execFileSync } from 'node:child_process'
import { readFileSync, realpathSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { readConfig } from './sdd-config.mjs'

/** Policy type ids, stable across organizations and languages (display names are localized). */
export const MINIMUM_REVIEWERS = 'fa4e907d-c16b-4a4c-9dfa-4906e5d171dd'
/** "Require a merge strategy" (shown as "Limit merge types"). */
export const MERGE_STRATEGY = 'fa4e907d-c16b-4a4c-9dfa-4916e5d171ab'

const SHA = /^[0-9a-f]{40}$/
const BRANCH = /^[A-Za-z0-9._/-]+$/

export class InputError extends Error {}

/**
 * The organization URL, project and repository of an Azure Repos remote URL, or null.
 * @param {string} url
 * @returns {{ organization: string, project: string, repository: string } | null}
 */
export function parseRemote(url) {
  const text = String(url).trim()
  const decode = (/** @type {string} */ x) => {
    try {
      return decodeURIComponent(x)
    } catch {
      return null
    }
  }
  const make = (/** @type {string} */ organization, /** @type {string} */ project, /** @type {string} */ repository) => {
    const p = decode(project)
    const r = decode(repository.replace(/\.git$/, ''))
    return p && r ? { organization, project: p, repository: r } : null
  }
  let m = /^https:\/\/(?:[^@/]+@)?dev\.azure\.com\/([^/]+)\/([^/]+)\/_git\/([^/?#]+)\/?$/i.exec(text)
  if (m) {
    return make(`https://dev.azure.com/${m[1]}`, m[2], m[3])
  }
  m = /^https:\/\/(?:[^@/]+@)?([A-Za-z0-9-]+)\.visualstudio\.com\/(?:DefaultCollection\/)?([^/]+)\/_git\/([^/?#]+)\/?$/i.exec(text)
  if (m) {
    return make(`https://${m[1]}.visualstudio.com`, m[2], m[3])
  }
  m = /^(?:ssh:\/\/)?[^@]+@(?:ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com)[:/]v3\/([^/]+)\/([^/]+)\/([^/]+)$/i.exec(text)
  if (m) {
    return make(`https://dev.azure.com/${m[1]}`, m[2], m[3])
  }
  return null
}

/**
 * Problems with a PR as an archive PR, and its head and source branch.
 * @param {any} pr
 * @param {string} defaultBranch
 * @returns {{ problems: string[], head: string | null, source: string | null }}
 */
export function checkPr(pr, defaultBranch) {
  if (pr === null || typeof pr !== 'object' || Array.isArray(pr)) {
    throw new InputError('not a pull request object')
  }
  const problems = []
  if (pr.status !== 'active') {
    problems.push(`the PR is ${String(pr.status)}, not active`)
  }
  if (pr.isDraft === true) {
    problems.push('the PR is a draft')
  }
  if (pr.forkSource !== undefined && pr.forkSource !== null) {
    problems.push('the PR comes from a fork: never adopt it, its author controls its pipeline')
  }
  if (pr.targetRefName !== `refs/heads/${defaultBranch}`) {
    problems.push(`the PR targets ${String(pr.targetRefName)}, not refs/heads/${defaultBranch}`)
  }
  const source = typeof pr.sourceRefName === 'string' && pr.sourceRefName.startsWith('refs/heads/') ? pr.sourceRefName : null
  if (source === null) {
    problems.push('the PR does not come from a branch of this repository')
  }
  if (pr.mergeStatus !== 'succeeded') {
    problems.push(`the PR's merge status is ${String(pr.mergeStatus)}, not succeeded (a conflict, or not computed yet)`)
  }
  const commit = pr.lastMergeSourceCommit?.commitId
  const head = typeof commit === 'string' && SHA.test(commit) ? commit : null
  if (head === null) {
    problems.push('the PR has no last merge source commit')
  }
  return { problems, head, source }
}

/**
 * A PR's policy evaluations as a list, from `az repos pr policy list -o json` or the REST
 * `{ value: [...] }`.
 * @param {unknown} input
 * @returns {any[]}
 */
function evaluationsOf(input) {
  const list = Array.isArray(input) ? input : (input !== null && typeof input === 'object' && Array.isArray(/** @type {any} */ (input).value) ? /** @type {any} */ (input).value : null)
  if (list === null) {
    throw new InputError('policy evaluations must be a JSON array')
  }
  for (const x of list) {
    const config = x?.configuration
    if (config === null || typeof config !== 'object' || typeof x.status !== 'string') {
      throw new InputError('a policy evaluation has no configuration or status')
    }
    // Read strictly: a field missing from the shape az prints must never make a policy count as
    // non-blocking.
    if (typeof config.isBlocking !== 'boolean') {
      throw new InputError('a policy evaluation has no boolean configuration.isBlocking')
    }
  }
  return list
}

/** @param {any} config */
function isLive(config) {
  return config.isEnabled !== false && config.isDeleted !== true
}

/**
 * The state of a PR's blocking policies, and a line for each one not met.
 *   none       the branch has no policy evaluations at all: a completion without a bypass is
 *              still checked by Azure DevOps itself, and nothing may be bypassed
 *   approved   every enabled blocking policy is approved or not applicable
 *   pending    none failed, but one is still queued or running
 *   reviewers  the only unmet blocking policies are "Minimum number of reviewers"
 *   blocked    any other blocking policy failed or isn't met
 * @param {unknown} input
 * @returns {{ state: 'none' | 'approved' | 'pending' | 'reviewers' | 'blocked', unmet: string[] }}
 */
export function judgePolicies(input) {
  const list = evaluationsOf(input)
  if (list.length === 0) {
    return { state: 'none', unmet: [] }
  }
  let blocked = false
  let pending = false
  let reviewers = false
  const unmet = []
  for (const x of list) {
    const config = x.configuration
    if (!config.isBlocking || !isLive(config)) {
      continue
    }
    if (x.status === 'approved' || x.status === 'notApplicable') {
      continue
    }
    const typeId = String(config.type?.id ?? '').toLowerCase()
    const name = String(config.type?.displayName ?? (typeId || 'unknown policy')).replace(/[\r\n\t]+/g, ' ')
    unmet.push(`- ${name}: ${x.status}`)
    if (typeId === MINIMUM_REVIEWERS) {
      reviewers = true
    } else if (x.status === 'queued' || x.status === 'running') {
      pending = true
    } else {
      blocked = true
    }
  }
  const state = blocked ? 'blocked' : pending ? 'pending' : reviewers ? 'reviewers' : 'approved'
  return { state, unmet }
}

/** Merge strategies in the order sdd prefers them: every one keeps the archive's tree. */
const STRATEGIES = Object.freeze([
  ['noFastForward', 'allowNoFastForward'],
  ['rebaseMerge', 'allowRebaseMerge'],
  ['squash', 'allowSquash'],
  ['rebase', 'allowRebase'],
])

/**
 * The merge strategy to complete with: the first sdd prefers that every enabled "Require a
 * merge strategy" policy allows, or noFastForward when there is no such policy. Named
 * explicitly, so a bypass can never complete with a strategy the repository forbids.
 * @param {unknown} input policy evaluations
 * @returns {{ strategy: string } | { refused: string }}
 */
export function mergeStrategy(input) {
  let allowed = new Set(STRATEGIES.map(([name]) => name))
  for (const x of evaluationsOf(input)) {
    const config = x.configuration
    if (String(config.type?.id ?? '').toLowerCase() !== MERGE_STRATEGY || !isLive(config)) {
      continue
    }
    const settings = config.settings !== null && typeof config.settings === 'object' ? config.settings : {}
    const named = STRATEGIES.some(([, key]) => typeof settings[key] === 'boolean')
    /** @type {Set<string>} */
    let here
    if (named) {
      here = new Set(STRATEGIES.filter(([, key]) => settings[key] === true).map(([name]) => name))
    } else if (settings.useSquashMerge === true) {
      // The policy's older form: squash only.
      here = new Set(['squash'])
    } else {
      here = new Set(['noFastForward'])
    }
    allowed = new Set([...allowed].filter(name => here.has(name)))
  }
  const strategy = STRATEGIES.map(([name]) => name).find(name => allowed.has(name))
  return strategy === undefined ? { refused: 'the merge-strategy policies allow no merge type in common' } : { strategy }
}

/**
 * Reviewers who voted Reject (-10) or Waiting for author (-5) on a PR.
 * @param {any} pr
 * @returns {string[]}
 */
export function vetoes(pr) {
  if (pr.reviewers === undefined || pr.reviewers === null) {
    return []
  }
  if (!Array.isArray(pr.reviewers)) {
    throw new InputError('the PR\'s reviewers must be an array')
  }
  return pr.reviewers
    .filter((/** @type {any} */ x) => typeof x?.vote === 'number' && x.vote < 0)
    .map((/** @type {any} */ x) => `${String(x.displayName ?? x.uniqueName ?? 'a reviewer').replace(/[\r\n\t]+/g, ' ')} (${x.vote === -10 ? 'Reject' : 'Waiting for author'})`)
}

/**
 * The PATCH body that completes a PR pinned to a commit, or the reason it may not.
 * The bypass is narrow: only with --bypass-reviewers and `archiveBypassReviewers`, only when
 * "Minimum number of reviewers" is the only unmet blocking policy, and never past a reviewer
 * who voted Reject or Waiting for author.
 * @param {{ commit: string, pr: any, policies: unknown, bypassReviewers: boolean, message: string | null, config: ReturnType<typeof readConfig> }} options
 * @returns {{ body: object } | { refused: string }}
 */
export function completeBody({ commit, pr, policies, bypassReviewers, message, config }) {
  if (!SHA.test(commit)) {
    throw new InputError('--commit must be a full 40-character commit id')
  }
  if (pr === null || typeof pr !== 'object' || Array.isArray(pr)) {
    throw new InputError('not a pull request object')
  }
  if (config.host !== 'azure-devops') {
    return { refused: 'the repository is not on Azure DevOps (package.json sdd.host)' }
  }
  if (!config.autoMerge) {
    return { refused: 'autoMerge is false: the owner completes the PR' }
  }
  if (pr.lastMergeSourceCommit?.commitId !== commit) {
    return { refused: `the PR's head is no longer ${commit}: someone pushed after it was verified` }
  }
  const { state } = judgePolicies(policies)
  const merge = mergeStrategy(policies)
  if ('refused' in merge) {
    return merge
  }
  /** @type {Record<string, unknown>} */
  const completionOptions = { deleteSourceBranch: true, transitionWorkItems: false, mergeStrategy: merge.strategy }
  if (message !== null) {
    completionOptions.mergeCommitMessage = message
  }
  if (state === 'reviewers') {
    if (!bypassReviewers) {
      return { refused: 'a minimum-reviewer policy is not met: the PR needs a review' }
    }
    if (!config.archiveBypassReviewers) {
      return { refused: 'a minimum-reviewer policy is not met, and package.json sdd.archiveBypassReviewers is not true' }
    }
    const vetoed = vetoes(pr)
    if (vetoed.length > 0) {
      return { refused: `a reviewer voted against the PR, which is never bypassed: ${vetoed.join(', ')}` }
    }
    completionOptions.bypassPolicy = true
    completionOptions.bypassReason = `sdd: archive PR verified mechanical at ${commit} with the default branch's scripts; only the reviewer count was unmet`
  } else if (state !== 'approved' && state !== 'none') {
    return { refused: `the PR's policies are ${state}` }
  }
  return { body: { status: 'completed', lastMergeSourceCommit: { commitId: commit }, completionOptions } }
}

/** @param {string} source */
function readJson(source) {
  let text
  try {
    text = readFileSync(source === '-' ? 0 : source, 'utf8')
  } catch (error) {
    throw new InputError(`cannot read ${source}: ${error instanceof Error ? error.message : error}`)
  }
  // az on Windows can write a UTF-8 byte order mark first.
  const BOM = 0xfeff
  try {
    return JSON.parse(text.charCodeAt(0) === BOM ? text.slice(1) : text)
  } catch {
    throw new InputError(`${source === '-' ? 'standard input' : source} is not valid JSON`)
  }
}

function isMain() {
  try {
    return process.argv[1] !== undefined && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href
  } catch {
    return false
  }
}

const USAGE = `usage: sdd-azure.mjs remote [<url>]
       sdd-azure.mjs pr --default <branch> [<file>|-]
       sdd-azure.mjs policies [<file>|-]
       sdd-azure.mjs complete-body --commit <sha> --pr <file>|- --policies <file>|- [--bypass-reviewers] [--message <text>]`

/** @param {string[]} args */
function main(args) {
  const usage = () => {
    console.error(USAGE)
    return 2
  }
  const [cmd, ...rest] = args
  if (cmd === 'remote') {
    if (rest.length > 1) {
      return usage()
    }
    let url = rest[0]
    if (url === undefined) {
      try {
        url = execFileSync('git', ['remote', 'get-url', 'origin'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
      } catch {
        console.log('- this repository has no origin remote')
        return 1
      }
    }
    const remote = parseRemote(url)
    if (remote === null) {
      console.log('- origin is not an Azure Repos remote')
      return 1
    }
    console.log(JSON.stringify(remote))
    return 0
  }
  if (cmd === 'pr') {
    if (rest[0] !== '--default' || rest.length < 2 || rest.length > 3 || !BRANCH.test(rest[1])) {
      return usage()
    }
    const { problems, head, source } = checkPr(readJson(rest[2] ?? '-'), rest[1])
    if (problems.length > 0) {
      for (const x of problems) {
        console.log(`- ${x}`)
      }
      return 1
    }
    console.log(`head=${head}`)
    console.log(`source=${source}`)
    return 0
  }
  if (cmd === 'policies') {
    if (rest.length > 1) {
      return usage()
    }
    const { state, unmet } = judgePolicies(readJson(rest[0] ?? '-'))
    for (const x of unmet) {
      console.log(x)
    }
    console.log(`policies=${state}`)
    return state === 'approved' || state === 'none' ? 0 : 1
  }
  if (cmd === 'complete-body') {
    /** @type {Record<string, string>} */
    const opts = {}
    let bypassReviewers = false
    for (let i = 0; i < rest.length; i++) {
      const flag = rest[i]
      if (flag === '--bypass-reviewers') {
        bypassReviewers = true
        continue
      }
      const value = rest[i + 1]
      // Each option once, and never a flag taken as another's value.
      if (!['--commit', '--pr', '--policies', '--message'].includes(flag) || flag in opts
        || value === undefined || value.startsWith('--')) {
        return usage()
      }
      opts[flag] = value
      i++
    }
    if (!opts['--commit'] || !opts['--pr'] || !opts['--policies'] || (opts['--pr'] === '-' && opts['--policies'] === '-')) {
      return usage()
    }
    const config = readConfig()
    const result = completeBody({
      commit: opts['--commit'],
      pr: readJson(opts['--pr']),
      policies: readJson(opts['--policies']),
      bypassReviewers,
      message: opts['--message'] ?? null,
      config,
    })
    if ('refused' in result) {
      console.log(`- not completing: ${result.refused}`)
      return 1
    }
    console.log(JSON.stringify(result.body, null, 2))
    return 0
  }
  return usage()
}

if (isMain()) {
  let code
  try {
    code = main(process.argv.slice(2))
  } catch (error) {
    console.error(`sdd-azure: ${error instanceof Error ? error.message : error}`)
    code = 3
  }
  process.exit(code)
}
