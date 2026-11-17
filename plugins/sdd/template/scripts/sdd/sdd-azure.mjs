// Installed by the sdd plugin (sdd-init). Re-running sdd-init overwrites this file.
//
// Azure DevOps helpers for /sdd:archive-pr. They decide; they never call Azure DevOps.
// sdd-azure-pr.sh fetches with `az` and passes the JSON in, so every rule here is testable
// offline.
//
//   node sdd-azure.mjs remote [<url>]
//       The organization URL, project and repository of an Azure Repos remote (default: the
//       `origin` of the current directory's repository, as git uses it and as configured), as
//       JSON. Exit 1 when it isn't one.
//
//   node sdd-azure.mjs find-archive [<file>|-]
//       Reads `az repos pr list -o json` and prints `pr=<id>` for each open archive PR from
//       this repository's own branches (an `archive/` branch or a title starting "Archive", no
//       fork), or `pr=none`.
//
//   node sdd-azure.mjs pr --default <branch> --project <name> --repository <name> [<file>|-]
//       Checks a PR as `az repos pr show -o json` prints it: in this project and repository
//       (`az repos pr show --id` finds PRs anywhere in the organization), active, not a draft,
//       not from a fork, without auto-complete set, from a branch named in safe characters into
//       the default branch, and its merge computed without conflicts. Prints a `- ` line per
//       problem; when there is none, `head=<sha>`, `source=<ref>`, `repository_id=<guid>` and
//       `project_id=<guid>`. Last line `pr=ok|wait|refused`: wait means the merge is still
//       being computed. Exit 0 ok, 4 wait, 1 refused.
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
// Exit status: 0 done, 1 refused or not met, 2 usage error, 3 bad input, 4 wait (pr).
import { execFileSync } from 'node:child_process'
import { readFileSync, realpathSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { readConfig } from './sdd-config.mjs'

/** Policy type ids, stable across organizations and languages (display names are localized). */
export const MINIMUM_REVIEWERS = 'fa4e907d-c16b-4a4c-9dfa-4906e5d171dd'
/** "Require a merge strategy" (shown as "Limit merge types"). */
export const MERGE_STRATEGY = 'fa4e907d-c16b-4a4c-9dfa-4916e5d171ab'

const SHA = /^[0-9a-f]{40}$/
const BRANCH = /^[A-Za-z0-9][A-Za-z0-9._/-]*$/
const GUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

export class InputError extends Error {}

/**
 * The organization URL, project and repository of an Azure Repos remote URL, or null.
 * @param {string} url
 * @returns {{ organization: string, project: string, repository: string } | null}
 */
export function parseRemote(url) {
  const text = String(url).trim()
  /** A decoded project or repository name, or null when it could break an argument or path. */
  const name = (/** @type {string | undefined} */ x) => {
    if (x === undefined || x === '') {
      return null
    }
    let decoded
    try {
      decoded = decodeURIComponent(x)
    } catch {
      return null
    }
    return /[/\\\x00-\x1f\x7f]/.test(decoded) || decoded === '.' || decoded === '..' ? null : decoded
  }
  const make = (/** @type {string} */ organization, /** @type {string | undefined} */ project, /** @type {string | undefined} */ repository) => {
    const r = name(repository?.replace(/\.git$/, ''))
    // A short URL (no project) names a repository whose project has the same name.
    const p = project === undefined ? r : name(project)
    return p && r ? { organization, project: p, repository: r } : null
  }
  const ORG = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

  // SSH: [ssh://]<user>@ssh.dev.azure.com[:22]:v3/<org>/<project>/<repo>, and vs-ssh.visualstudio.com.
  const ssh = /^(?:ssh:\/\/)?[A-Za-z0-9._-]+@(?:ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com)(?::22)?[:/]v3\/([^/]+)\/([^/]+)\/([^/]+?)\/?$/i.exec(text)
  if (ssh) {
    return ORG.test(ssh[1]) ? make(`https://dev.azure.com/${ssh[1]}`, ssh[2], ssh[3]) : null
  }

  // HTTPS: parsed, so the host is the host and never a path that happens to contain one.
  let parsed
  try {
    parsed = new URL(text)
  } catch {
    return null
  }
  if (parsed.protocol !== 'https:' || parsed.search !== '' || parsed.hash !== '') {
    return null
  }
  const segments = parsed.pathname.split('/').filter(x => x !== '')
  const git = segments.indexOf('_git')
  if (git < 0 || git !== segments.length - 2) {
    return null
  }
  const repository = segments[git + 1]
  const before = segments.slice(0, git)
  const host = parsed.hostname.toLowerCase()
  if (host === 'dev.azure.com') {
    // /<org>/<project>/_git/<repo>, or /<org>/_git/<repo>
    if (before.length < 1 || before.length > 2 || !ORG.test(before[0])) {
      return null
    }
    return make(`https://dev.azure.com/${before[0]}`, before[1], repository)
  }
  const vs = /^([a-z0-9][a-z0-9-]*)\.visualstudio\.com$/.exec(host)
  if (vs) {
    // /[DefaultCollection/]<project>/_git/<repo>, or /[DefaultCollection/]_git/<repo>
    const rest = before.length > 0 && before[0].toLowerCase() === 'defaultcollection' ? before.slice(1) : before
    if (rest.length > 1) {
      return null
    }
    return make(`https://${vs[1]}.visualstudio.com`, rest[0], repository)
  }
  return null
}

/**
 * Whether a source ref is safe to hand to git and the shell: a branch, in characters that need
 * no quoting anywhere. Git itself allows `$`, backticks and parentheses in branch names.
 * @param {unknown} ref
 * @returns {boolean}
 */
export function isSafeRef(ref) {
  return typeof ref === 'string' && /^refs\/heads\/[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(ref)
    && !ref.includes('..') && !ref.includes('//') && !ref.endsWith('/') && !ref.endsWith('.lock')
}

/** One line of untrusted text for a `- ` line. @param {unknown} text */
function oneLine(text) {
  return String(text).replace(/[\r\n\t]+/g, ' ')
}

/**
 * The ids of open archive PRs from this repository's own branches: an `archive/` branch or a
 * title starting "Archive", never from a fork.
 * @param {unknown} input `az repos pr list -o json` output
 * @returns {number[]}
 */
export function findArchivePrs(input) {
  if (!Array.isArray(input)) {
    throw new InputError('the PR list must be a JSON array')
  }
  return input
    .filter(x => x !== null && typeof x === 'object' && (x.forkSource === undefined || x.forkSource === null)
      && (String(x.sourceRefName ?? '').startsWith('refs/heads/archive/') || /^Archive\b/.test(String(x.title ?? '')))
      && Number.isInteger(x.pullRequestId))
    .map(x => x.pullRequestId)
}

/** Merge statuses that mean Azure DevOps hasn't finished computing the PR's merge yet. */
const MERGE_PENDING = new Set(['queued', 'notSet'])

/**
 * Whether a PR can be adopted as this repository's archive PR into its default branch.
 *   ok        it can: head, source and the repository and project ids are set
 *   wait      nothing is wrong yet, but its merge is still being computed: read it again
 *   refused   one or more problems, each a line
 * @param {any} pr as `az repos pr show -o json` prints it
 * @param {{ defaultBranch: string, project: string, repository: string }} expected
 * @returns {{ state: 'ok' | 'wait' | 'refused', problems: string[], head: string | null, source: string | null, repositoryId: string | null, projectId: string | null }}
 */
export function checkPr(pr, { defaultBranch, project, repository }) {
  if (pr === null || typeof pr !== 'object' || Array.isArray(pr)) {
    throw new InputError('not a pull request object')
  }
  const problems = []
  const same = (/** @type {unknown} */ a, /** @type {string} */ b) => typeof a === 'string' && a.toLowerCase() === b.toLowerCase()
  // `az repos pr show --id` finds a PR anywhere in the organization.
  if (!same(pr.repository?.name, repository) || !same(pr.repository?.project?.name, project)) {
    problems.push(`the PR belongs to ${oneLine(pr.repository?.project?.name)}/${oneLine(pr.repository?.name)}, not ${project}/${repository}`)
  }
  const repositoryId = typeof pr.repository?.id === 'string' && GUID.test(pr.repository.id) ? pr.repository.id : null
  const projectId = typeof pr.repository?.project?.id === 'string' && GUID.test(pr.repository.project.id) ? pr.repository.project.id : null
  if (repositoryId === null || projectId === null) {
    problems.push('the PR has no repository or project id')
  }
  if (pr.status !== 'active') {
    problems.push(`the PR is ${oneLine(pr.status)}, not active`)
  }
  if (pr.isDraft === true) {
    problems.push('the PR is a draft')
  }
  if (pr.forkSource !== undefined && pr.forkSource !== null) {
    problems.push('the PR comes from a fork: never adopt it, its author controls its pipeline')
  }
  if (pr.autoCompleteSetBy !== undefined && pr.autoCompleteSetBy !== null) {
    problems.push(`auto-complete is set (by ${oneLine(pr.autoCompleteSetBy?.displayName ?? 'someone')}): it would complete whatever commit is current, unverified. Cancel it first`)
  }
  if (pr.targetRefName !== `refs/heads/${defaultBranch}`) {
    problems.push(`the PR targets ${oneLine(pr.targetRefName)}, not refs/heads/${defaultBranch}`)
  }
  const source = isSafeRef(pr.sourceRefName) ? pr.sourceRefName : null
  if (source === null) {
    problems.push('the PR\'s source is not a branch of this repository named in safe characters ([A-Za-z0-9._/-])')
  }
  const commit = pr.lastMergeSourceCommit?.commitId
  const head = typeof commit === 'string' && SHA.test(commit) ? commit : null
  let wait = false
  if (MERGE_PENDING.has(pr.mergeStatus)) {
    wait = true
  } else if (pr.mergeStatus !== 'succeeded') {
    problems.push(`the PR's merge status is ${oneLine(pr.mergeStatus)} (a conflict, or a failed merge)`)
  } else if (head === null) {
    problems.push('the PR has no last merge source commit')
  }
  const state = problems.length > 0 ? 'refused' : wait ? 'wait' : 'ok'
  return { state, problems, head, source, repositoryId, projectId }
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
       sdd-azure.mjs find-archive [<file>|-]
       sdd-azure.mjs pr --default <branch> --project <name> --repository <name> [<file>|-]
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
    /** @type {string[]} */
    let urls = rest.length === 1 ? [rest[0]] : []
    if (rest.length === 0) {
      // The URL git uses (insteadOf applied), then the one configured: either may be the
      // Azure Repos URL when an alias or a mirror rewrites it.
      for (const args of [['remote', 'get-url', 'origin'], ['config', '--get', 'remote.origin.url']]) {
        try {
          urls.push(execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }))
        } catch {
          // no such remote, or no such setting
        }
      }
      if (urls.length === 0) {
        console.log('- this repository has no origin remote')
        return 1
      }
    }
    const remote = urls.map(parseRemote).find(x => x !== null)
    if (remote === undefined) {
      console.log('- origin is not an Azure Repos remote')
      return 1
    }
    console.log(JSON.stringify(remote))
    return 0
  }
  if (cmd === 'find-archive') {
    if (rest.length > 1) {
      return usage()
    }
    const ids = findArchivePrs(readJson(rest[0] ?? '-'))
    for (const id of ids) {
      console.log(`pr=${id}`)
    }
    if (ids.length === 0) {
      console.log('pr=none')
    }
    return 0
  }
  if (cmd === 'pr') {
    /** @type {Record<string, string>} */
    const opts = {}
    let file = '-'
    for (let i = 0; i < rest.length; i++) {
      const flag = rest[i]
      const value = rest[i + 1]
      if (['--default', '--project', '--repository'].includes(flag) && !(flag in opts) && value !== undefined && !value.startsWith('--')) {
        opts[flag] = value
        i++
      } else if (i === rest.length - 1 && !flag.startsWith('--')) {
        file = flag
      } else {
        return usage()
      }
    }
    if (!opts['--default'] || !opts['--project'] || !opts['--repository'] || !BRANCH.test(opts['--default'])) {
      return usage()
    }
    const result = checkPr(readJson(file), { defaultBranch: opts['--default'], project: opts['--project'], repository: opts['--repository'] })
    for (const x of result.problems) {
      console.log(`- ${x}`)
    }
    if (result.state === 'ok') {
      console.log(`head=${result.head}`)
      console.log(`source=${result.source}`)
      console.log(`repository_id=${result.repositoryId}`)
      console.log(`project_id=${result.projectId}`)
    } else if (result.state === 'wait') {
      console.log('- the PR\'s merge is still being computed: read it again shortly')
    }
    console.log(`pr=${result.state}`)
    return result.state === 'ok' ? 0 : result.state === 'wait' ? 4 : 1
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
