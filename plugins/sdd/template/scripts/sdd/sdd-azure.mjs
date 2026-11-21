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
//   node sdd-azure.mjs find-archive [--page-size <n>] [--after <file>] [<file>|-]
//       Reads `az repos pr list -o json` and prints `pr=<id>` for each open archive PR from
//       this repository's own branches (an `archive/` branch or a title starting "Archive", no
//       fork), or `pr=none`. With --page-size, a list that long may be cut short: exit 3. With
//       --after, a file holding the list past this one (`--skip <its length>`), which must be
//       empty (exit 3 otherwise): in case Azure DevOps returns a shorter page than asked for.
//
//   node sdd-azure.mjs pr --default <branch> --project <name> --repository <name> [<file>|-]
//       Checks a PR as `az repos pr show -o json` prints it: in this project and repository
//       (`az repos pr show --id` finds PRs anywhere in the organization), active, not a draft,
//       not from a fork, without auto-complete set, from a branch named in safe characters into
//       the default branch, and its merge computed without conflicts. Prints a `- ` line per
//       problem; when there is none, `head=<sha>`, `target=<sha>` (the target commit its merge
//       was computed against), `source=<ref>`, `repository_id=<guid>` and `project_id=<guid>`. Last line `pr=ok|wait|refused`: wait means the merge is still
//       being computed. Exit 0 ok, 4 wait, 1 refused.
//
//   node sdd-azure.mjs policies [--page-size <n>] [<file>|-]
//       Reads the PR's policy evaluations (`az repos pr policy list -o json`) and prints a `- `
//       line for each blocking policy that isn't met, then `policies=<state>`:
//         none       no policy evaluations: Azure DevOps still checks a completion itself
//         approved   every enabled blocking policy is approved or not applicable
//         pending    none failed, but a build is still queued or running: wait, read again
//         reviewers  the only unmet blocking policies are "Minimum number of reviewers",
//                    still waiting for approvals (queued)
//         blocked    any other blocking policy isn't met: a failed or expired build, a
//                    "Minimum number of reviewers" a vote rejected, and any other policy not
//                    yet approved (Required reviewers, comments, work items, a status), which
//                    waiting won't change
//       Every evaluation must carry a boolean `configuration.isBlocking`, and an approved build
//       a boolean `context.isExpired` (exit 3 otherwise), so a field missing from the input
//       never makes a policy count as non-blocking, or a build as current. With
//       --page-size, a list that long may be cut short: exit 3. Exit 0 for approved or none,
//       1 otherwise.
//
//   node sdd-azure.mjs installed [--lock <file>] [<dir>]
//       Was <dir>/node_modules (default: the current directory) installed from the lock file
//       (default: <dir>/package-lock.json)? Compares npm's record of the last install
//       (node_modules/.package-lock.json) with the lock, both ways: every installed package
//       must be one the lock names, at its version and link, and its integrity (its resolved
//       URL where the lock pins no integrity); every package the lock pins, other than an
//       optional or peer one, must be installed; OpenSpec's own package.json must carry the
//       lock's version. So an install from another lock (a PR branch's `npm ci`, say) fails it.
//       It reads npm's records, never the files: code that rewrote files in node_modules, or
//       the record itself (an install script, a PR's script run in this checkout), isn't
//       caught. Prints a `- ` line per problem, then `installed=ok|mismatch`. Exit 0 ok, 1
//       mismatch, 3 a lock or record npm 6 or a lockfileVersion 1 lock wrote (no `packages`).
//
//   node sdd-azure.mjs complete-body --commit <sha> --target <sha> --pr <file>
//                                    --policies <file> --merge-policies <file>
//                                    [--bypass-reviewers] [--message <text>]
//       Prints the body of the PATCH that completes the PR, pinned to <sha>
//       (`lastMergeSourceCommit`), the source commit Azure DevOps is asked to complete. A push
//       after verification should make completion fail; that rests on Azure DevOps' behavior,
//       which no test here exercises, so confirm the completed commit afterwards. The target
//       has no such pin in the API: complete-body refuses unless the PR's merge was computed
//       against --target (`lastMergeTargetCommit`), the default branch's commit the PR was
//       verified against. A push to the default branch between this read and the PATCH still
//       lands the PR on a target nobody verified; the confirmation afterwards reports that as
//       `unverified`. The merge strategy is named: the first of squash, noFastForward,
//       rebaseMerge, rebase that every "Require a merge strategy" policy in --merge-policies
//       (the branch's configurations, `az repos policy list --branch`) or --policies (the PR's
//       evaluations) allows. The body deletes the source branch (`deleteSourceBranch`; an
//       archive branch has no further use) and transitions no work items. Refuses (exit 1,
//       a `- not completing:` line) unless the repository is on Azure DevOps, `autoMerge` is
//       on, the PR's head is still <sha>, its merge was computed against --target, no reviewer
//       voted Reject or Waiting for author, every required reviewer approved, and the policies
//       are `approved` or `none`. The one exception: policies
//       `reviewers`, --bypass-reviewers given and `archiveBypassReviewers` true; then the body
//       bypasses policy, with a reason. A bypass skips every policy when Azure DevOps
//       completes, including anything that changed after these reads. Settings come from this
//       checkout's package.json (sdd-config.mjs), never a PR's.
//
// Exit status: 0 done, 1 refused or not met, 2 usage error, 3 bad input, 4 wait (pr).
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, realpathSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { readConfig } from './sdd-config.mjs'
import { clean } from './sdd-specs.mjs'

/** Policy type ids, stable across organizations and languages (display names are localized). */
export const MINIMUM_REVIEWERS = 'fa4e907d-c16b-4a4c-9dfa-4906e5d171dd'
/** "Require a merge strategy" (shown as "Limit merge types"). */
export const MERGE_STRATEGY = 'fa4e907d-c16b-4a4c-9dfa-4916e5d171ab'

const SHA = /^[0-9a-f]{40}$/
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

/**
 * Whether a branch name (without refs/heads/) is safe, by isSafeRef's rule. sdd-azure-pr.sh's
 * safe_branch is the same rule in bash; the tests try the same names on both.
 * @param {unknown} name
 * @returns {boolean}
 */
export function isSafeBranch(name) {
  return typeof name === 'string' && isSafeRef(`refs/heads/${name}`)
}

/**
 * One line of untrusted text for a `- ` line, with logging-command syntax broken (`##[`, `::`,
 * `##vso[`): sdd-specs.mjs's clean, so every sdd script breaks it the same way.
 */
const oneLine = clean

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
  const onto = pr.lastMergeTargetCommit?.commitId
  const target = typeof onto === 'string' && SHA.test(onto) ? onto : null
  if (!wait && pr.mergeStatus === 'succeeded' && target === null) {
    problems.push('the PR has no last merge target commit')
  }
  const state = problems.length > 0 ? 'refused' : wait ? 'wait' : 'ok'
  return { state, problems, head, target, source, repositoryId, projectId }
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

/** Build Validation: the one policy that finishes on its own, so the only one worth waiting for. */
export const BUILD = '0609b952-1397-4640-95ec-e00a01b2c241'

/**
 * The state of a PR's blocking policies, and a line for each one not met.
 *   none       the branch has no policy evaluations at all: a completion without a bypass is
 *              still checked by Azure DevOps itself, and nothing may be bypassed
 *   approved   every enabled blocking policy is approved or not applicable
 *   pending    none failed, but a build is still queued or running
 *   reviewers  the only unmet blocking policies are "Minimum number of reviewers", still
 *              waiting for approvals (queued)
 *   blocked    any other blocking policy isn't met: a failed or expired build, a "Minimum
 *              number of reviewers" a vote rejected, and any other policy not yet approved
 *              (Required reviewers, comments, work items, a status), which waiting won't change
 * An approved Build Validation must say whether it expired (a boolean context.isExpired).
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
    const typeId = String(config.type?.id ?? '').toLowerCase()
    const name = oneLine(config.type?.displayName ?? (typeId || 'unknown policy'))
    // An expired build reads approved, but Azure DevOps won't complete on it. Read strictly: an
    // approved build that doesn't say whether it expired is never taken as current.
    if (typeId === BUILD && x.status === 'approved' && typeof x.context?.isExpired !== 'boolean') {
      throw new InputError('an approved build policy evaluation has no boolean context.isExpired')
    }
    const expired = typeId === BUILD && x.context?.isExpired === true
    if ((x.status === 'approved' && !expired) || x.status === 'notApplicable') {
      continue
    }
    unmet.push(`- ${name}: ${expired ? 'expired (queue the build again)' : oneLine(x.status)}`)
    // Only a count still waiting for approvals (queued) is the reviewer count alone: rejected
    // means a vote against, and any other status is unexpected. A bypass skips neither.
    if (typeId === MINIMUM_REVIEWERS && x.status === 'queued') {
      reviewers = true
    } else if (typeId === BUILD && !expired && (x.status === 'queued' || x.status === 'running')) {
      pending = true
    } else {
      blocked = true
    }
  }
  const state = blocked ? 'blocked' : pending ? 'pending' : reviewers ? 'reviewers' : 'approved'
  return { state, unmet }
}

/**
 * Merge strategies in the order sdd prefers them. Squash first: it lands one commit, so none of
 * the branch's intermediate commits (which verify doesn't judge) appears in the default
 * branch's history. Its tree is the verified result only because the PR's head was verified on
 * top of the target it merges onto (complete-body checks the target). When the branch's
 * policies don't allow squash, a later strategy brings those intermediate commits along: their
 * end result is the verified tree, but nobody verified each of them.
 */
const STRATEGIES = Object.freeze([
  ['squash', 'allowSquash'],
  ['noFastForward', 'allowNoFastForward'],
  ['rebaseMerge', 'allowRebaseMerge'],
  ['rebase', 'allowRebase'],
])

const OPENSPEC = 'node_modules/@fission-ai/openspec'

/** @param {Record<string, any>} object @param {string} key */
function own(object, key) {
  return Object.prototype.hasOwnProperty.call(object, key) ? object[key] : undefined
}

/**
 * A lock file's packages: its `packages` object, entries by install path.
 * @param {unknown} lock
 * @param {string} what
 * @returns {Record<string, any>}
 */
function packagesOf(lock, what) {
  const packages = lock !== null && typeof lock === 'object' ? /** @type {any} */ (lock).packages : undefined
  if (packages === null || typeof packages !== 'object' || Array.isArray(packages)) {
    throw new InputError(`${what} has no packages object (lockfileVersion 2 or later)`)
  }
  return packages
}

/**
 * Was node_modules installed from the lock? Compares npm's record of the install
 * (node_modules/.package-lock.json) with the lock both ways, and OpenSpec's own package.json
 * version with the lock's. What identifies a package is its version and link, and its
 * integrity; its resolved URL only where the lock pins no integrity, since a registry setting
 * (a mirror, replace-registry-host) can record another URL for the same tarball. Problems, one
 * per line; none means it was.
 * @param {{ lock: unknown, installed: unknown, openspecVersion: unknown }} input
 * @returns {string[]}
 */
export function installProblems({ lock, installed, openspecVersion }) {
  const want = packagesOf(lock, 'package-lock.json')
  const got = packagesOf(installed, 'node_modules/.package-lock.json')
  /** @param {string} path */
  const nameOf = path => oneLine(path.replace(/^node_modules\//, ''))
  /** @param {unknown} value */
  const shown = value => oneLine(value === undefined || value === null ? 'none' : typeof value === 'object' ? JSON.stringify(value) : value)
  const problems = []
  if (own(want, OPENSPEC) === undefined) {
    problems.push('package-lock.json pins no @fission-ai/openspec')
  }
  for (const [path, entry] of Object.entries(got)) {
    const pinned = own(want, path)
    if (pinned === undefined || pinned === null || typeof pinned !== 'object') {
      problems.push(`${nameOf(path)}: installed, but package-lock.json doesn't name it`)
      continue
    }
    const fields = ['version', 'link', pinned.integrity === undefined ? 'resolved' : 'integrity']
    for (const field of fields) {
      const a = entry?.[field] ?? undefined
      const b = pinned[field] ?? undefined
      // A field the lock leaves out pins nothing, except link: absent means not a link.
      if (a !== b && (b !== undefined || field === 'link')) {
        problems.push(`${nameOf(path)}: installed ${field} ${shown(a)}, the lock pins ${shown(b)}`)
      }
    }
  }
  for (const [path, pinned] of Object.entries(want)) {
    // Installed packages only (the root and workspace folders aren't), and not those npm may
    // leave out: optional ones (another platform's), and peers.
    if (!path.startsWith('node_modules/') || pinned === null || typeof pinned !== 'object'
      || pinned.optional === true || pinned.devOptional === true || pinned.peer === true) {
      continue
    }
    if (own(got, path) === undefined) {
      problems.push(`${nameOf(path)}: the lock pins it, but it isn't installed`)
    }
  }
  const pinnedVersion = own(want, OPENSPEC)?.version
  if (pinnedVersion !== undefined && openspecVersion !== pinnedVersion) {
    problems.push(`@fission-ai/openspec's package.json says ${shown(openspecVersion)}, the lock pins ${shown(pinnedVersion)}`)
  }
  return problems
}

/**
 * Policy configurations, from `az repos policy list --branch <b> --repository-id <id> -o json`
 * (or the REST `{ value: [...] }`), or the `configuration` of each policy evaluation.
 * @param {unknown} input
 * @returns {any[]}
 */
function configurationsOf(input) {
  const list = Array.isArray(input) ? input : (input !== null && typeof input === 'object' && Array.isArray(/** @type {any} */ (input).value) ? /** @type {any} */ (input).value : null)
  if (list === null) {
    throw new InputError('policy configurations must be a JSON array')
  }
  return list.map(x => {
    const config = x !== null && typeof x === 'object' && x.configuration !== undefined ? x.configuration : x
    if (config === null || typeof config !== 'object' || config.type === null || typeof config.type !== 'object') {
      throw new InputError('a policy configuration has no type')
    }
    return config
  })
}

/**
 * The merge strategy to complete with: the first sdd prefers that every enabled "Require a
 * merge strategy" policy given allows, or squash when there is none. Named explicitly, so
 * neither the API default nor a bypass completes with a strategy the repository forbids.
 * A policy lists only the strategies it allows (`allowSquash: true`, ...); one with none of
 * them is the older form, `useSquashMerge`, or no-fast-forward only. Settings that aren't an
 * object are bad input.
 * @param {unknown} input policy configurations, or evaluations carrying them
 * @returns {{ strategy: string } | { refused: string }}
 */
export function mergeStrategy(input) {
  let allowed = new Set(STRATEGIES.map(([name]) => name))
  for (const config of configurationsOf(input)) {
    if (String(config.type.id ?? '').toLowerCase() !== MERGE_STRATEGY || !isLive(config)) {
      continue
    }
    // Read strictly: settings that can't be read are never taken as some default.
    if (config.settings === null || typeof config.settings !== 'object' || Array.isArray(config.settings)) {
      throw new InputError('a merge-strategy policy has no settings object')
    }
    const settings = config.settings
    const named = STRATEGIES.some(([, key]) => typeof settings[key] === 'boolean')
    /** @type {Set<string>} */
    let here
    if (named) {
      here = new Set(STRATEGIES.filter(([, key]) => settings[key] === true).map(([name]) => name))
    } else if (settings.useSquashMerge === true) {
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
 * Reviewers who stand against completing: anyone who voted Reject (-10) or Waiting for author
 * (-5), and any required reviewer who hasn't approved.
 * @param {any} pr
 * @returns {string[]}
 */
export function reviewerObjections(pr) {
  // Read strictly: az always prints the list (empty when nobody reviews), and every vote is a
  // number. Neither missing may read as "no objection".
  if (!Array.isArray(pr.reviewers)) {
    throw new InputError('the PR\'s reviewers must be an array')
  }
  const out = []
  for (const x of pr.reviewers) {
    const who = oneLine(x?.displayName ?? x?.uniqueName ?? 'a reviewer')
    if (typeof x?.vote !== 'number') {
      throw new InputError(`a reviewer's vote must be a number (${who})`)
    }
    const vote = x.vote
    if (vote < 0) {
      out.push(`${who} voted ${vote <= -10 ? 'Reject' : 'Waiting for author'}`)
    } else if (x?.isRequired === true && vote <= 0) {
      out.push(`${who} is a required reviewer and hasn't approved`)
    }
  }
  return out
}

/**
 * The PATCH body that completes a PR pinned to a commit, or the reason it may not.
 * Never past a reviewer who voted against it or a required reviewer who hasn't approved, in any
 * policy state. The bypass is narrow: only with --bypass-reviewers and `archiveBypassReviewers`,
 * and only when "Minimum number of reviewers" is the only unmet blocking policy. It still
 * bypasses every policy at the moment Azure DevOps completes, so anything that changes between
 * these reads and the PATCH (a new vote, an expired build) is bypassed too; sdd-azure-pr.sh
 * reads everything again right before, to keep that window to seconds.
 * @param {{ commit: string, target: string, pr: any, policies: unknown, mergePolicies: unknown, bypassReviewers: boolean, message: string | null, config: ReturnType<typeof readConfig> }} options
 * @returns {{ body: object } | { refused: string }}
 */
export function completeBody({ commit, target, pr, policies, mergePolicies, bypassReviewers, message, config }) {
  if (!SHA.test(commit)) {
    throw new InputError('--commit must be a full 40-character commit id')
  }
  if (!SHA.test(target)) {
    throw new InputError('--target must be a full 40-character commit id')
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
  const mergedOnto = pr.lastMergeTargetCommit?.commitId
  if (mergedOnto !== target) {
    return { refused: `the PR's merge was computed against ${oneLine(mergedOnto ?? 'nothing')}, not ${target}: the default branch moved after it was verified, or Azure DevOps hasn't recomputed the merge yet` }
  }
  const objections = reviewerObjections(pr)
  if (objections.length > 0) {
    return { refused: `a reviewer stands against the PR, which sdd never completes past: ${objections.join('; ')}` }
  }
  const { state } = judgePolicies(policies)
  // The branch's configurations and the PR's own evaluations, which carry every policy that
  // applies to the PR: one inherited, or scoped by prefix, that the branch's list misses counts.
  const merge = mergeStrategy([...configurationsOf(mergePolicies), ...configurationsOf(evaluationsOf(policies))])
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
    completionOptions.bypassPolicy = true
    completionOptions.bypassReason = `sdd: archive PR verified mechanical at ${commit} with the default branch's scripts; only the reviewer count was unmet`
  } else if (state !== 'approved' && state !== 'none') {
    return { refused: `the PR's policies are ${state}` }
  }
  return { body: { status: 'completed', lastMergeSourceCommit: { commitId: commit }, completionOptions } }
}

/**
 * `[--page-size <n>] [<file>|-]`: the arguments of a command that reads one page of az output.
 * @param {string[]} rest
 */
function pageArgs(rest) {
  let pageSize = 0
  let file = '-'
  let ok = true
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === '--page-size' && /^[1-9][0-9]*$/.test(rest[i + 1] ?? '')) {
      pageSize = Number(rest[++i])
    } else if (i === rest.length - 1 && !rest[i].startsWith('--')) {
      file = rest[i]
    } else {
      ok = false
    }
  }
  return { pageSize, file, ok }
}

/**
 * A list as long as the page az was asked for may be cut short: it is never read as complete.
 * @param {unknown} input
 * @param {number} pageSize 0 for no page
 * @param {string} what
 */
function fullPage(input, pageSize, what) {
  const list = Array.isArray(input) ? input : /** @type {any} */ (input)?.value
  if (pageSize > 0 && Array.isArray(list) && list.length >= pageSize) {
    throw new InputError(`${list.length} ${what} fill a whole page of ${pageSize}: the list may be cut short, too many to read as one complete list`)
  }
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
       sdd-azure.mjs find-archive [--page-size <n>] [--after <file>] [<file>|-]
       sdd-azure.mjs pr --default <branch> --project <name> --repository <name> [<file>|-]
       sdd-azure.mjs policies [--page-size <n>] [<file>|-]
       sdd-azure.mjs installed [--lock <file>] [<dir>]
       sdd-azure.mjs complete-body --commit <sha> --target <sha> --pr <file> --policies <file>
                                   --merge-policies <file> [--bypass-reviewers] [--message <text>]`

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
    // --after <file> once, from a file (standard input is the list's).
    const at = rest.indexOf('--after')
    const after = at < 0 ? null : rest[at + 1]
    const args = at < 0 ? rest : [...rest.slice(0, at), ...rest.slice(at + 2)]
    const { pageSize, file, ok } = pageArgs(args)
    if (!ok || args.includes('--after') || (after !== null && (after === undefined || after === '-' || after.startsWith('--')))) {
      return usage()
    }
    const list = readJson(file)
    fullPage(list, pageSize, 'open PRs')
    if (after !== null) {
      const more = readJson(after)
      const past = Array.isArray(more) ? more : /** @type {any} */ (more)?.value
      if (!Array.isArray(past)) {
        throw new InputError('the list past the first page must be a JSON array')
      }
      if (past.length > 0) {
        throw new InputError('the list past the first page isn\'t empty: Azure DevOps returned a shorter page than asked for, so the list is cut short')
      }
    }
    const ids = findArchivePrs(list)
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
    if (!opts['--default'] || !opts['--project'] || !opts['--repository'] || !isSafeBranch(opts['--default'])) {
      return usage()
    }
    const result = checkPr(readJson(file), { defaultBranch: opts['--default'], project: opts['--project'], repository: opts['--repository'] })
    for (const x of result.problems) {
      console.log(`- ${x}`)
    }
    if (result.state === 'ok') {
      console.log(`head=${result.head}`)
      console.log(`target=${result.target}`)
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
    const { pageSize, file, ok } = pageArgs(rest)
    if (!ok) {
      return usage()
    }
    const list = readJson(file)
    fullPage(list, pageSize, 'policy evaluations')
    const { state, unmet } = judgePolicies(list)
    for (const x of unmet) {
      console.log(x)
    }
    console.log(`policies=${state}`)
    return state === 'approved' || state === 'none' ? 0 : 1
  }
  if (cmd === 'installed') {
    let lockFile
    let args = rest
    if (args[0] === '--lock') {
      if (args[1] === undefined || args[1].startsWith('--')) {
        return usage()
      }
      lockFile = args[1]
      args = args.slice(2)
    }
    if (args.length > 1 || (args.length === 1 && args[0].startsWith('--'))) {
      return usage()
    }
    const dir = args[0] ?? '.'
    lockFile = lockFile ?? join(dir, 'package-lock.json')
    const recordFile = join(dir, 'node_modules', '.package-lock.json')
    const packageFile = join(dir, OPENSPEC, 'package.json')
    /** @type {string[]} */
    let problems
    if (!existsSync(lockFile)) {
      problems = [`there is no lock file (${oneLine(lockFile)})`]
    } else if (!existsSync(recordFile)) {
      problems = ['node_modules has no record of an npm install (node_modules/.package-lock.json)']
    } else {
      problems = installProblems({
        lock: readJson(lockFile),
        installed: readJson(recordFile),
        openspecVersion: existsSync(packageFile) ? readJson(packageFile)?.version : undefined,
      })
    }
    for (const x of problems) {
      console.log(`- ${x}`)
    }
    console.log(`installed=${problems.length === 0 ? 'ok' : 'mismatch'}`)
    return problems.length === 0 ? 0 : 1
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
      if (!['--commit', '--target', '--pr', '--policies', '--merge-policies', '--message'].includes(flag) || flag in opts
        || value === undefined || value.startsWith('--')) {
        return usage()
      }
      opts[flag] = value
      i++
    }
    const stdin = ['--pr', '--policies', '--merge-policies'].filter(x => opts[x] === '-').length
    if (!opts['--commit'] || !opts['--target'] || !opts['--pr'] || !opts['--policies'] || !opts['--merge-policies'] || stdin > 1) {
      return usage()
    }
    const config = readConfig()
    const result = completeBody({
      commit: opts['--commit'],
      target: opts['--target'],
      pr: readJson(opts['--pr']),
      policies: readJson(opts['--policies']),
      mergePolicies: readJson(opts['--merge-policies']),
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
