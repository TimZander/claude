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
//         approved   every enabled blocking policy is approved or not applicable
//         pending    none failed, but one is still queued or running: wait and read again
//         reviewers  the only unmet blocking policies are "Minimum number of reviewers"
//         blocked    any other blocking policy failed or isn't met (a failed build, required
//                    reviewers, linked work items, comments, a status policy)
//       Exit 0 for approved, 1 otherwise.
//
//   node sdd-azure.mjs complete-body --commit <sha> --policies <file>|- [--bypass-reviewers]
//                                    [--message <text>]
//       Prints the body of the PATCH that completes the PR, pinned to <sha>
//       (`lastMergeSourceCommit`), the source commit Azure DevOps is asked to complete, so a
//       push after verification should make completion fail (confirm the completed commit
//       afterwards: this rests on Azure DevOps' behavior, which no test here exercises). Refuses (exit 1, a `- ` line) unless the
//       repository is on Azure DevOps, `autoMerge` is on, and the policies are `approved`; or
//       they are `reviewers`, --bypass-reviewers was given and `archiveBypassReviewers` is true,
//       when the body bypasses policy with a reason. Settings come from this checkout's
//       package.json (sdd-config.mjs), never a PR's.
//
// Exit status: 0 done, 1 refused or not met, 2 usage error, 3 bad input.
import { execFileSync } from 'node:child_process'
import { readFileSync, realpathSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { readConfig } from './sdd-config.mjs'

/** Policy type ids, stable across organizations and languages (display names are localized). */
export const MINIMUM_REVIEWERS = 'fa4e907d-c16b-4a4c-9dfa-4906e5d171dd'

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
 * The state of a PR's blocking policies, and a line for each one not met.
 * @param {unknown} input `az repos pr policy list -o json` output, or the REST `{ value: [...] }`
 * @returns {{ state: 'approved' | 'pending' | 'reviewers' | 'blocked', unmet: string[] }}
 */
export function judgePolicies(input) {
  const list = Array.isArray(input) ? input : (input !== null && typeof input === 'object' && Array.isArray(/** @type {any} */ (input).value) ? /** @type {any} */ (input).value : null)
  if (list === null) {
    throw new InputError('policy evaluations must be a JSON array')
  }
  let blocked = false
  let pending = false
  let reviewers = false
  const unmet = []
  for (const x of list) {
    const config = x?.configuration
    if (config === null || typeof config !== 'object' || typeof x.status !== 'string') {
      throw new InputError('a policy evaluation has no configuration or status')
    }
    if (config.isBlocking !== true || config.isEnabled === false || config.isDeleted === true) {
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

/**
 * The PATCH body that completes a PR pinned to a commit, or the reason it may not.
 * @param {{ commit: string, policies: unknown, bypassReviewers: boolean, message: string | null, config: ReturnType<typeof readConfig> }} options
 * @returns {{ body: object } | { refused: string }}
 */
export function completeBody({ commit, policies, bypassReviewers, message, config }) {
  if (!SHA.test(commit)) {
    throw new InputError('--commit must be a full 40-character commit id')
  }
  if (config.host !== 'azure-devops') {
    return { refused: 'the repository is not on Azure DevOps (package.json sdd.host)' }
  }
  if (!config.autoMerge) {
    return { refused: 'autoMerge is false: the owner completes the PR' }
  }
  const { state } = judgePolicies(policies)
  /** @type {Record<string, unknown>} */
  const completionOptions = { deleteSourceBranch: true, transitionWorkItems: false }
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
    completionOptions.bypassPolicy = true
    completionOptions.bypassReason = `sdd: archive PR verified mechanical at ${commit} with the default branch's scripts`
  } else if (state !== 'approved') {
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
  try {
    return JSON.parse(text.replace(/^﻿/, ''))
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
       sdd-azure.mjs complete-body --commit <sha> --policies <file>|- [--bypass-reviewers] [--message <text>]`

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
    return state === 'approved' ? 0 : 1
  }
  if (cmd === 'complete-body') {
    let commit = null
    let policies = null
    let message = null
    let bypassReviewers = false
    for (let i = 0; i < rest.length; i++) {
      const value = rest[i + 1]
      if (rest[i] === '--bypass-reviewers') {
        bypassReviewers = true
      } else if (value === undefined) {
        return usage()
      } else if (rest[i] === '--commit') {
        commit = value
        i++
      } else if (rest[i] === '--policies') {
        policies = value
        i++
      } else if (rest[i] === '--message') {
        message = value
        i++
      } else {
        return usage()
      }
    }
    if (commit === null || policies === null) {
      return usage()
    }
    const config = readConfig()
    const result = completeBody({ commit, policies: readJson(policies), bypassReviewers, message, config })
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
