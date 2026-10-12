#!/usr/bin/env bash
# Mutation-test a change set: run a test suite against deliberately broken source and
# report which mutations SURVIVED (i.e. which tests pass against broken code).
#
# This script owns the mechanical, destructive, and verification steps — the ones a human
# or an agent drops near the end of a long campaign. It does NOT choose the mutations: the
# caller applies each mutation itself (semantic mutations grounded in what the change
# *claims* to do beat a generic operator sweep), then hands control back here to run,
# record, and restore.
#
# Usage:
#   mutation-test.sh begin  --test-cmd <cmd> (--base <branch> | --file <path> | --files-from <list>) [options]
#   mutation-test.sh run    --session <dir> --name <name> [--description <text>]
#   mutation-test.sh finish --session <dir> [--allow-test-artifacts] [--no-final-check]
#   mutation-test.sh status --session <dir>
#
# Lifecycle:
#   begin   Refuse a dirty tree, resolve target files, copy them to a backup OUTSIDE the
#           repo, prove the suite is green, then record the reference tree state (after the
#           baseline run, so the suite's own caches are not mistaken for drift).
#   run     (caller has already edited the source) Save the mutated files for reproduction,
#           run the suite under a timeout, classify the result, then ALWAYS restore by
#           copying the backup back — never `git checkout`/`restore`/`stash`, which would
#           silently revert uncommitted work and leave the run looking green. Also proves
#           nothing outside the target set was touched.
#   finish  Prove the tree matches the reference, re-run the suite to prove it is green
#           again, and print the report. A run that cannot prove this is a failed run.
#
# Results are one of: caught, survived, flaky, timeout, error. Only `caught` and `survived`
# are verdicts; the rest mean nothing was proven and are reported as inconclusive. A harness
# that cannot tell "survived" from "never ran" is the same defect as the vacuous tests it
# exists to find.
#
# Exit codes:
#   0  success
#   1  general error (not a repo, missing session, bad target, ...)
#   2  usage error
#   3  the session has no green baseline (begin aborted, or run/finish on such a session),
#      or no mutation was applied
#   4  dirty working tree without --allow-dirty
#   5  tree verification failed — the working tree does NOT match the reference
#   6  the tree verified, but the suite is not green
#
# IMPORTANT: on ANY non-zero exit from `run`, verify the working tree before continuing.
# `run` arms its restore before any validation that can fail, but the caller applies the
# mutation before `run` is ever invoked, so a failure in the caller's own edit step is
# outside this script's reach.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
    cat <<USAGE
usage: $SCRIPT_NAME begin  --test-cmd <cmd> (--base <branch> | --file <path> | --files-from <list>) [options]
       $SCRIPT_NAME run    --session <dir> --name <name> [--description <text>]
       $SCRIPT_NAME finish --session <dir> [--allow-test-artifacts] [--no-final-check]
       $SCRIPT_NAME status --session <dir>

begin options:
  --test-cmd <cmd>        Shell command that runs the suite. Required. Exit 0 == green.
  --base <branch>         Target the files changed vs <branch> (git diff --name-only <branch>...HEAD).
  --file <path>           Target an explicit file. Repeatable. Combines with --base.
  --files-from <listfile> Target every path listed (one per line) in <listfile>.
  --exclude <glob>        Drop resolved targets matching <glob>. Repeatable. Every exclusion
                          is reported, and so is an --exclude that matches nothing.
  --timeout <seconds>     Per-run timeout. Default 600. A mutation that hangs is restored, not left.
  --session-dir <dir>     Where to keep the backup and artifacts. Must be OUTSIDE the repo.
                          Default: a fresh mktemp dir. Pass this when the reproduction
                          commands need to outlive TMPDIR cleanup.
  --rerun-caught          Re-run every 'caught' result once to filter flaky failures. Use on any
                          suite with known intermittency — a flake reads as a catch and hides a
                          survivor. Timeouts are always re-run regardless of this flag.
  --verify-green          After restoring each mutation, re-run the suite to prove the tree is
                          green again before the next mutation, so failures cannot cascade.
                          Doubles the campaign's cost; 'finish' always does this once.
  --allow-dirty           Proceed with uncommitted changes. The backup still protects them, but
                          you are acknowledging the baseline is not a known-good commit.
  --allow-test-artifacts  Let the suite leave UNTRACKED files (caches, coverage) without failing
                          verification. Tracked-file drift always fails. Also accepted by
                          'finish', so a campaign need not be re-run to set it.

run options:
  --session <dir>         Session directory printed by 'begin'.
  --name <name>           Short identifier for this mutation. Letters, digits, dot, underscore
                          and hyphen only; no spaces, no '.' or '..'.
  --description <text>    What this mutation breaks, in the change's own terms.

finish options:
  --session <dir>         Session directory printed by 'begin'.
  --allow-test-artifacts  As above; overrides what 'begin' recorded.
  --no-final-check        Skip the closing suite run that proves the restored tree is green.
USAGE
}

usage_error() {
    if [ -n "${1:-}" ]; then
        echo "error: $1" >&2
    fi
    usage >&2
    exit 2
}

die() { echo "error: $1" >&2; exit "${2:-1}"; }

# Placeholder for an empty TSV field. `IFS=$'\t' read` collapses runs of tabs (tab is IFS
# whitespace), so an genuinely empty column would shift every later field left and silently
# swallow the mutation's description — which is the deliverable.
TSV_NONE="-"

# --- shared helpers ---------------------------------------------------------

# Guard every `shift 2`. Without this, a trailing flag with no value makes `shift` fail and
# `set -e` exits 1 with no diagnostic at all — a silent bail-out where a usage error is due.
need_value() {
    local flag="$1" remaining="$2"
    if [ "$remaining" -lt 2 ]; then
        usage_error "$flag requires a value"
    fi
}

# The git toplevel of a directory, or empty if it isn't inside a repository. Used instead of
# string-comparing absolute paths: on Windows `pwd` yields /c/... while `git rev-parse` yields
# C:/..., so a textual prefix test would wrongly call every path "outside the repository".
toplevel_of() {
    ( cd "$1" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null ) || true
}

# The nearest existing ancestor of a path (the path itself if it exists).
nearest_existing_dir() {
    local p="$1" parent
    while [ -n "$p" ] && [ ! -d "$p" ]; do
        parent="$(dirname -- "$p")"
        if [ "$parent" = "$p" ]; then
            break
        fi
        p="$parent"
    done
    printf '%s' "$p"
}

# Repo-relative path for an existing file, resolved through git so it works for absolute and
# relative inputs alike, from any subdirectory, on any platform.
repo_relative_path() {
    local f="$1" d b
    d="$(dirname -- "$f")"
    b="$(basename -- "$f")"
    printf '%s%s' "$( cd "$d" && git rev-parse --show-prefix )" "$b"
}

# Make a possibly-relative path absolute against a given directory. Handles Windows drive
# letters so a C:/... path is not treated as relative.
absolutize() {
    local p="$1" base="$2"
    case "$p" in
        /*|[A-Za-z]:[/\\]*) printf '%s' "$p";;
        *) printf '%s/%s' "$base" "$p";;
    esac
}

read_meta() {
    local session="$1" key="$2"
    if [ ! -f "$session/meta/$key" ]; then
        die "session at '$session' is missing meta/$key — not a mutation-test session?"
    fi
    cat "$session/meta/$key"
}

# `git status --porcelain` honours status.showUntrackedFiles, so a repo configured with `no`
# would report a tree with untracked files as clean — defeating both the dirty-tree refusal
# and the drift check. Pin the setting rather than inherit it.
porcelain() {
    git -c status.showUntrackedFiles=normal status --porcelain
}

# Validate a session directory and load its metadata. Refuses a session whose baseline was
# never proven green: `begin` writes the backup and targets before running the baseline, so
# an aborted session is a complete-looking session that would produce fabricated verdicts.
require_session() {
    local session="$1"
    if [ ! -d "$session" ]; then
        die "session directory '$session' does not exist"
    fi
    if [ ! -f "$session/targets" ]; then
        die "'$session' is not a mutation-test session (no targets file)"
    fi
    if [ "$(cat "$session/meta/baseline" 2>/dev/null || true)" != "green" ]; then
        echo "error: session '$session' has no green baseline — 'begin' never got past the" >&2
        echo "       baseline run, so any result from it would be meaningless." >&2
        echo "       Start a fresh session. Backups from this one are under $session/backup." >&2
        exit 3
    fi
}

# Refuse a session that belongs to a different repository. A stale --session across agent
# turns is a plausible mistake and would otherwise produce a confident clean bill of health
# for a repo the script never looked at.
require_matching_repo() {
    local recorded="$1" here
    here="$(toplevel_of "$PWD")"
    if [ -n "$here" ] && [ "$here" != "$recorded" ]; then
        die "this session belongs to '$recorded' but you are in '$here'. Re-run from that repository, or use the right session."
    fi
}

# --- running the suite ------------------------------------------------------

TIMEOUT_KIND=""

# `command -v timeout` does not prove GNU timeout: BusyBox's has no -k, and a Windows
# timeout.exe earlier on PATH returns a code that would read as a red baseline.
resolve_timeout_kind() {
    if [ -n "$TIMEOUT_KIND" ]; then
        return 0
    fi
    if command -v timeout >/dev/null 2>&1 && timeout --version 2>/dev/null | head -1 | grep -qi coreutils; then
        TIMEOUT_KIND="gnu"
    else
        TIMEOUT_KIND="poll"
    fi
    if [ -n "${MUTATION_TEST_FORCE_POLL:-}" ]; then
        TIMEOUT_KIND="poll"
    fi
}

# Run a command string with a wall-clock timeout. Returns the command's exit code, or 124 if
# it was killed for exceeding the timeout. stdin is /dev/null so a suite that reads stdin
# cannot consume the caller's input or block forever.
run_with_timeout() {
    local secs="$1" cmd="$2" log="$3" rc=0
    resolve_timeout_kind
    if [ "$TIMEOUT_KIND" = "gnu" ]; then
        timeout -k 10 "$secs" bash -c "$cmd" >"$log" 2>&1 </dev/null || rc=$?
        return "$rc"
    fi
    # Portable fallback for hosts without GNU coreutils (e.g. stock macOS). Job control gives
    # the child its own process group so the whole tree is signalled, not just `bash -c`;
    # otherwise a timed-out pytest/jest leaves workers running against the next mutation.
    local deadline now pid
    deadline=$(( $(date +%s) + secs ))
    set -m
    bash -c "$cmd" >"$log" 2>&1 </dev/null &
    pid=$!
    set +m
    while kill -0 "$pid" 2>/dev/null; do
        now="$(date +%s)"
        if [ "$now" -ge "$deadline" ]; then
            kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
            sleep 2
            kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
    done
    wait "$pid" || rc=$?
    return "$rc"
}

# Map a suite exit code onto what it actually proves.
#   green    — the suite passed
#   red      — the suite failed
#   timedout — killed for running too long. GNU timeout returns 124 normally, but 137 when the
#              suite ignored SIGTERM and had to be SIGKILLed. Treating 137 as a plain failure
#              would file a hang as a catch — the exact false catch this tool exists to find.
#   harness  — the command could not be invoked at all; nothing about the code was tested.
#              Note: a runner that returns a failure COUNT as its exit code can land here on a
#              real catch. The downgrade is to "inconclusive", never to a false verdict, and
#              the report names the exit code so the ambiguity is visible.
classify_rc() {
    case "$1" in
        0) echo green;;
        124|137) echo timedout;;
        125|126|127) echo harness;;
        *) echo red;;
    esac
}

# Pull the line that names the failing assertion out of a suite log, so the report can say
# WHICH assertion fired. A mutation that trips an assertion other than the one it targeted is
# not coverage of the behaviour it broke, and a pass/fail column cannot show that.
#
# Two passes: assertion-shaped lines first, then a broader net. The alternations cover pytest,
# unittest, jest (● / ✕), vitest (×), mocha, bats (^not ok), go test (--- FAIL:), cargo
# (lowercase `assertion ... failed`, `panicked at`), xUnit/NUnit (Assert.*), MSBuild
# (error CSxxxx), and JUnit. Anything unmatched yields the placeholder, which the report
# renders as "none captured" rather than as "no failure".
failure_signature() {
    local log="$1" sig=""
    if [ -f "$log" ]; then
        sig="$(grep -m1 -aE '(AssertionError|[Aa]ssert(ion)?[^[:alnum:]]*(failed|Failed)|Assert\.[A-Za-z]+|^not ok|--- FAIL:|panicked at|Expected[^[:alnum:]]|to (be|equal|have)|●[[:space:]]|✕|✗|✘|×)' "$log" 2>/dev/null || true)"
        if [ -z "$sig" ]; then
            sig="$(grep -m1 -aE '(FAILED|FAIL[: ]|Traceback|panic:|error [A-Z]+[0-9]+:|error:|ERROR:)' "$log" 2>/dev/null || true)"
        fi
    fi
    sig="$(printf '%s' "$sig" | tr -d '\r' | tr '\t\n|' '   ' | sed 's/^[[:space:]]*//' | cut -c1-110)"
    if [ -z "$sig" ]; then
        printf '%s' "$TSV_NONE"
    else
        printf '%s' "$sig"
    fi
}

# --- restore ----------------------------------------------------------------

# Set by 'run' before it breaks anything. The EXIT trap fires after the function's locals are
# gone, so the restore paths have to live at global scope.
TRAP_SESSION=""
TRAP_REPO_ROOT=""

# Copy every target file back from the backup. This is the ONLY restore mechanism:
# `git checkout -- <path>` would also discard uncommitted work in the same file and leave the
# campaign looking green, which is exactly the failure this script exists to prevent.
# Each file is attempted independently — one failure must not abandon the rest mutated.
#
# The restored file is touched afterwards: `cp -p` puts back the ORIGINAL mtime, which is
# older than the artifact an incremental build produced from the mutated source, so make /
# tsc --incremental / cargo / ccache would skip the rebuild and the next suite would execute
# the previous mutation's compiled code.
restore_from_backup() {
    local session="$1" repo_root="$2" rel failed=0
    while IFS= read -r rel; do
        if [ -z "$rel" ]; then
            continue
        fi
        if ! mkdir -p "$repo_root/$(dirname -- "$rel")" 2>/dev/null; then
            echo "restore: cannot create directory for '$rel'" >&2
            failed=1
            continue
        fi
        if ! cp -p "$session/backup/$rel" "$repo_root/$rel" 2>/dev/null; then
            echo "restore: FAILED to restore '$rel'" >&2
            failed=1
            continue
        fi
        touch "$repo_root/$rel" 2>/dev/null || true
    done < "$session/targets"
    return "$failed"
}

# Restore once, announce it, and disarm. Called both from the signal/EXIT traps and from the
# normal path, so there is exactly one restore implementation and no window without one.
trap_restore() {
    if [ -z "$TRAP_SESSION" ]; then
        return 0
    fi
    local s="$TRAP_SESSION" r="$TRAP_REPO_ROOT"
    TRAP_SESSION=""
    echo "note: restoring target files from the backup copy." >&2
    if ! restore_from_backup "$s" "$r"; then
        echo "error: restore reported failures — the working tree may still be mutated." >&2
        echo "       Restore manually: cp \"$s/backup/<path>\" \"$r/<path>\"" >&2
    fi
}

# Signal handlers must EXIT. A handler that merely returns lets bash resume the interrupted
# script, which would then classify a suite that was killed — or, worse, re-run it against the
# source the handler just restored — and record a verdict nobody observed.
arm_restore_trap() {
    TRAP_SESSION="$1"
    TRAP_REPO_ROOT="$2"
    trap trap_restore EXIT
    trap 'trap_restore; exit 130' INT
    trap 'trap_restore; exit 143' TERM
    trap 'trap_restore; exit 129' HUP
}

# Byte-compare every target file against its backup. Prints drifted paths, returns 1 on drift.
verify_targets_match_backup() {
    local session="$1" repo_root="$2" rel drift=0
    while IFS= read -r rel; do
        if [ -z "$rel" ]; then
            continue
        fi
        if ! cmp -s "$session/backup/$rel" "$repo_root/$rel"; then
            echo "$rel"
            drift=1
        fi
    done < "$session/targets"
    return "$drift"
}

# --- tree drift -------------------------------------------------------------

# Content hashes for tracked files that were already dirty when the reference was taken.
# `git status --porcelain` reports name+status only, so without this a file already showing
# ` M` could be rewritten arbitrarily by the campaign and its status line would not change.
write_dirty_hashes() {
    local repo_root="$1" out="$2" p
    : > "$out"
    while IFS= read -r p; do
        if [ -n "$p" ] && [ -f "$repo_root/$p" ]; then
            printf '%s\t%s\n' "$(git -C "$repo_root" hash-object -- "$p")" "$p" >> "$out"
        fi
    done < <(git -C "$repo_root" diff --name-only HEAD)
}

# Compare the working tree against the session reference.
# Sets DRIFT_TEXT (human-readable) and returns:
#   0  no drift
#   1  untracked-only drift (forgivable with --allow-test-artifacts)
#   2  tracked drift, or the reference itself is missing/unreadable
DRIFT_TEXT=""
compare_to_reference() {
    local session="$1" repo_root="$2" now_file="$3"
    DRIFT_TEXT=""

    # A missing reference is not "no drift". Swallowing it would let a verification step claim
    # a fact it never checked.
    if [ ! -f "$session/porcelain.baseline" ]; then
        DRIFT_TEXT="reference snapshot $session/porcelain.baseline is missing — nothing can be verified against it"
        return 2
    fi

    ( cd "$repo_root" && porcelain ) > "$now_file"

    local delta tracked=0 any=0 line entry
    delta="$(diff "$session/porcelain.baseline" "$now_file" || true)"
    if [ -n "$delta" ]; then
        while IFS= read -r line; do
            case "$line" in
                '< '*|'> '*)
                    entry="${line:2}"
                    any=1
                    DRIFT_TEXT="${DRIFT_TEXT}${entry}"$'\n'
                    case "$entry" in
                        '?? '*) ;;
                        *) tracked=1;;
                    esac;;
            esac
        done <<< "$delta"
    fi

    # Content check for files that were already dirty at reference time.
    if [ -f "$session/dirty-hashes" ]; then
        local want have p
        while IFS=$'\t' read -r want p; do
            if [ -z "$want" ] || [ -z "$p" ]; then
                continue
            fi
            have=""
            if [ -f "$repo_root/$p" ]; then
                have="$(git -C "$repo_root" hash-object -- "$p" 2>/dev/null || true)"
            fi
            if [ "$have" != "$want" ]; then
                any=1
                tracked=1
                DRIFT_TEXT="${DRIFT_TEXT}content changed in already-modified tracked file: $p"$'\n'
            fi
        done < "$session/dirty-hashes"
    fi

    if [ "$any" -eq 0 ]; then
        return 0
    fi
    if [ "$tracked" -eq 1 ]; then
        return 2
    fi
    return 1
}

# --- begin ------------------------------------------------------------------

cmd_begin() {
    local test_cmd="" base="" timeout_secs=600 session_dir=""
    local rerun_caught=0 allow_dirty=0 allow_artifacts=0 verify_green=0
    local explicit_files=() excludes=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --test-cmd) need_value "$1" "$#"; test_cmd="$2"; shift 2;;
            --base) need_value "$1" "$#"; base="$2"; shift 2;;
            --file) need_value "$1" "$#"; explicit_files+=("$2"); shift 2;;
            --exclude) need_value "$1" "$#"; excludes+=("$2"); shift 2;;
            --files-from)
                need_value "$1" "$#"
                local listfile="$2" line
                if [ ! -f "$listfile" ]; then
                    usage_error "--files-from '$listfile' does not exist"
                fi
                # `|| [ -n "$line" ]` keeps a final entry with no trailing newline; the CR strip
                # makes a CRLF list file (the norm on Windows) work.
                while IFS= read -r line || [ -n "$line" ]; do
                    line="$(printf '%s' "$line" | tr -d '\r')"
                    if [ -n "$line" ]; then
                        explicit_files+=("$line")
                    fi
                done < "$listfile"
                shift 2;;
            --timeout) need_value "$1" "$#"; timeout_secs="$2"; shift 2;;
            --session-dir) need_value "$1" "$#"; session_dir="$2"; shift 2;;
            --rerun-caught) rerun_caught=1; shift;;
            --verify-green) verify_green=1; shift;;
            --allow-dirty) allow_dirty=1; shift;;
            --allow-test-artifacts) allow_artifacts=1; shift;;
            -h|--help) usage; exit 0;;
            *) usage_error "unknown argument: $1";;
        esac
    done

    if [ -z "$test_cmd" ]; then
        usage_error "--test-cmd is required"
    fi
    # `case`, not `grep`: grep matches line by line, so a multi-line value whose first line is
    # clean would pass an anchored pattern.
    case "$timeout_secs" in
        ''|*[!0-9]*) usage_error "--timeout must be a whole number of seconds";;
    esac
    if [ "$timeout_secs" -le 0 ]; then
        usage_error "--timeout must be greater than zero"
    fi
    if [ -z "$base" ] && [ "${#explicit_files[@]}" -eq 0 ]; then
        usage_error "give --base <branch>, --file <path>, or --files-from <listfile> to say what to mutate"
    fi

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        die "not inside a git repository"
    fi
    local repo_root invocation_cwd
    repo_root="$(git rev-parse --show-toplevel)"
    invocation_cwd="$PWD"

    if ! git rev-parse --verify --quiet HEAD >/dev/null; then
        die "this repository has no commits yet — there is nothing to mutation-test against"
    fi

    # A dirty tree means the baseline is not a known-good state: a survivor could be an
    # artifact of uncommitted work rather than of the mutation.
    if [ -n "$(porcelain)" ]; then
        if [ "$allow_dirty" -eq 0 ]; then
            echo "error: working tree is dirty. Mutation testing assumes a known-good baseline." >&2
            echo "       Commit or discard the changes, or pass --allow-dirty to acknowledge." >&2
            git status --short >&2
            exit 4
        fi
        echo "warning: proceeding with a dirty working tree (--allow-dirty)." >&2
    fi

    # Resolve target files. Explicit paths are resolved against the INVOCATION directory, not
    # the repo root — a relative --file from a subdirectory must mean what the caller typed.
    local candidates=() f
    if [ -n "$base" ]; then
        if ! git rev-parse --verify --quiet "$base" >/dev/null; then
            die "--base '$base' is not a known ref. Fetch it first (git fetch origin $base)."
        fi
        # Capture to a file rather than a process substitution: `set -e` cannot see a failure
        # inside <(...), so a real git error (no merge base, shallow clone) would surface as
        # the misleading "no mutable target files resolved".
        local diff_out
        diff_out="$(mktemp)"
        if ! git -c core.quotePath=false diff --name-only -z "$base...HEAD" > "$diff_out" 2>"$diff_out.err"; then
            echo "error: 'git diff --name-only $base...HEAD' failed:" >&2
            cat "$diff_out.err" >&2
            rm -f "$diff_out" "$diff_out.err"
            exit 1
        fi
        while IFS= read -r -d '' f; do
            if [ -n "$f" ]; then
                candidates+=("$f")
            fi
        done < "$diff_out"
        rm -f "$diff_out" "$diff_out.err"
    fi
    for f in ${explicit_files[@]+"${explicit_files[@]}"}; do
        local abs
        abs="$(absolutize "$f" "$invocation_cwd")"
        if [ ! -e "$abs" ]; then
            die "target '$f' does not exist"
        fi
        if [ "$(toplevel_of "$(dirname -- "$abs")")" != "$repo_root" ]; then
            die "target '$f' is outside the repository at $repo_root"
        fi
        candidates+=("$(repo_relative_path "$abs")")
    done

    cd "$repo_root"

    # Drop duplicates, non-files, symlinks, and --exclude matches. Every drop is announced:
    # a silent cap reads as "covered everything" when it did not.
    local targets=() c seen dup ex
    local matched_excludes=""
    for c in ${candidates[@]+"${candidates[@]}"}; do
        dup=0
        for seen in ${targets[@]+"${targets[@]}"}; do
            if [ "$seen" = "$c" ]; then
                dup=1
                break
            fi
        done
        if [ "$dup" -eq 1 ]; then
            echo "note: '$c' listed more than once — using it once" >&2
            continue
        fi
        dup=0
        for ex in ${excludes[@]+"${excludes[@]}"}; do
            # shellcheck disable=SC2254
            case "$c" in
                $ex)
                    echo "note: excluding '$c' (matches --exclude '$ex')" >&2
                    matched_excludes="$matched_excludes|$ex|"
                    dup=1
                    break;;
            esac
        done
        if [ "$dup" -eq 1 ]; then
            continue
        fi
        case "$c" in
            *$'\n'*) echo "note: skipping a path containing a newline (unsupported)" >&2; continue;;
        esac
        if [ -L "$repo_root/$c" ]; then
            # cp/cmp both follow links, so a "restore" would write through the link into a file
            # that may live outside the repo and outside the verified set.
            echo "note: skipping '$c' (symlink — cannot prove byte-identical restoration)" >&2
            continue
        fi
        if [ ! -f "$repo_root/$c" ]; then
            echo "note: skipping '$c' (not a regular file in the working tree)" >&2
            continue
        fi
        case "$(basename -- "$c")" in
            *[Tt]est*|*[Ss]pec*|*.md|*.json|*.lock|*.txt|*.snap)
                echo "note: '$c' looks like a test, doc, or data file — mutating it proves nothing about the change. Use --exclude to drop it." >&2;;
        esac
        targets+=("$c")
    done
    # An --exclude that matched nothing is usually a typo, and silently leaving the file in the
    # campaign is exactly the silent cap this script refuses elsewhere.
    for ex in ${excludes[@]+"${excludes[@]}"}; do
        case "$matched_excludes" in
            *"|$ex|"*) ;;
            *) echo "note: --exclude '$ex' matched no target" >&2;;
        esac
    done
    if [ "${#targets[@]}" -eq 0 ]; then
        die "no mutable target files resolved"
    fi

    # The session lives OUTSIDE the repo on purpose: a backup inside the working tree would
    # show up in `git status --porcelain` and corrupt the very check that proves the tree was
    # restored. Check BEFORE creating, so a rejected path leaves nothing behind.
    local created_session=0
    if [ -n "$session_dir" ]; then
        session_dir="$(absolutize "$session_dir" "$invocation_cwd")"
        if [ "$(toplevel_of "$(nearest_existing_dir "$session_dir")")" = "$repo_root" ]; then
            die "--session-dir must be outside the repository (it would perturb git status)"
        fi
        if [ -e "$session_dir/targets" ]; then
            die "'$session_dir' already holds a mutation-test session. Pick a fresh directory — reusing one would re-baseline against whatever is currently on disk."
        fi
        if [ ! -d "$session_dir" ]; then
            mkdir -p "$session_dir"
            created_session=1
        fi
        session_dir="$(cd "$session_dir" && pwd)"
    else
        local tmp_parent="${TMPDIR:-/tmp}"
        if [ "$(toplevel_of "$(nearest_existing_dir "$tmp_parent")")" = "$repo_root" ]; then
            die "TMPDIR resolves inside the repository; pass --session-dir pointing outside it"
        fi
        session_dir="$(mktemp -d "$tmp_parent/mutation-test-XXXXXX")"
        created_session=1
    fi
    # Only tighten permissions on a directory we made — silently re-moding one the user chose
    # would be a surprise, and the backup may hold uncommitted source.
    if [ "$created_session" -eq 1 ]; then
        chmod 700 "$session_dir" 2>/dev/null || true
    fi

    mkdir -p "$session_dir/meta" "$session_dir/backup" "$session_dir/mutations"
    printf '%s' "$repo_root"       > "$session_dir/meta/repo_root"
    printf '%s' "$test_cmd"        > "$session_dir/meta/test_cmd"
    printf '%s' "$timeout_secs"    > "$session_dir/meta/timeout"
    printf '%s' "$rerun_caught"    > "$session_dir/meta/rerun_caught"
    printf '%s' "$verify_green"    > "$session_dir/meta/verify_green"
    printf '%s' "$allow_artifacts" > "$session_dir/meta/allow_test_artifacts"
    printf '%s' "$base"            > "$session_dir/meta/base"
    printf '%s' "pending"          > "$session_dir/meta/baseline"
    : > "$session_dir/results.tsv"

    local t
    printf '%s\n' "${targets[@]}" > "$session_dir/targets"
    for t in "${targets[@]}"; do
        mkdir -p "$session_dir/backup/$(dirname -- "$t")"
        if ! cp -p "$repo_root/$t" "$session_dir/backup/$t"; then
            die "could not back up '$t' — refusing to mutate a file that cannot be restored"
        fi
    done

    # Print the session before the baseline runs: on a red baseline the backup already exists,
    # and a caller who never saw the path cannot clean it up.
    echo "SESSION=$session_dir"
    echo "TARGETS=${#targets[@]}"

    # Baseline: the suite must be green before anything is broken, or every later result is
    # meaningless.
    echo "Running baseline suite (timeout ${timeout_secs}s)..." >&2
    local rc=0
    run_with_timeout "$timeout_secs" "$test_cmd" "$session_dir/baseline.log" || rc=$?
    if [ "$rc" -ne 0 ]; then
        local kind
        kind="$(classify_rc "$rc")"
        case "$kind" in
            timedout)
                echo "error: baseline suite did not finish within ${timeout_secs}s. Raise --timeout or speed up the suite." >&2
                echo "BASELINE=timeout";;
            harness)
                echo "error: baseline test command could not be run (exit $rc). Check --test-cmd." >&2
                echo "BASELINE=harness";;
            *)
                echo "error: baseline suite is not green (exit $rc). Fix the suite before mutating." >&2
                echo "BASELINE=red";;
        esac
        echo "       Output: $session_dir/baseline.log" >&2
        tail -20 "$session_dir/baseline.log" >&2 || true
        exit 3
    fi

    # Record the reference tree state AFTER the baseline run, so caches and coverage files the
    # suite itself creates are part of the reference rather than drift attributed to the
    # campaign. The hash list covers tracked files that are already dirty, whose porcelain
    # status line would not change even if their content did.
    ( cd "$repo_root" && porcelain ) > "$session_dir/porcelain.baseline"
    write_dirty_hashes "$repo_root" "$session_dir/dirty-hashes"

    printf '%s' "green" > "$session_dir/meta/baseline"
    echo "BASELINE=green"
}

# --- run --------------------------------------------------------------------

cmd_run() {
    # Pre-scan for --session so the restore trap is armed before ANY validation that can exit.
    # The caller mutated the tree before calling us; an unknown flag or a missing value must
    # not be the reason a mutation ships.
    local pre_session="" i argc=$#
    local argv=("$@")
    for (( i=0; i<argc; i++ )); do
        if [ "${argv[$i]}" = "--session" ] && [ $((i+1)) -lt "$argc" ]; then
            pre_session="$(absolutize "${argv[$((i+1))]}" "$PWD")"
            break
        fi
    done
    if [ -n "$pre_session" ] && [ -f "$pre_session/targets" ] && [ -f "$pre_session/meta/repo_root" ]; then
        arm_restore_trap "$pre_session" "$(cat "$pre_session/meta/repo_root")"
    fi

    local session="" name="" description=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --session) need_value "$1" "$#"; session="$2"; shift 2;;
            --name) need_value "$1" "$#"; name="$2"; shift 2;;
            --description) need_value "$1" "$#"; description="$2"; shift 2;;
            -h|--help) usage; exit 0;;
            *) usage_error "unknown argument: $1";;
        esac
    done

    if [ -z "$session" ]; then
        usage_error "--session is required"
    fi
    # Absolutize BEFORE any cd: a relative session path would otherwise resolve against the
    # repo root once we move there, and could even name a different directory.
    session="$(absolutize "$session" "$PWD")"
    require_session "$session"

    local repo_root test_cmd timeout_secs rerun_caught verify_green allow_artifacts
    repo_root="$(read_meta "$session" repo_root)"
    test_cmd="$(read_meta "$session" test_cmd)"
    timeout_secs="$(read_meta "$session" timeout)"
    rerun_caught="$(read_meta "$session" rerun_caught)"
    verify_green="$(read_meta "$session" verify_green)"
    allow_artifacts="$(read_meta "$session" allow_test_artifacts)"
    if [ ! -d "$repo_root" ]; then
        die "recorded repo root '$repo_root' no longer exists"
    fi
    if [ "$(toplevel_of "$repo_root")" != "$repo_root" ]; then
        die "recorded repo root '$repo_root' is no longer a git repository"
    fi
    require_matching_repo "$repo_root"
    arm_restore_trap "$session" "$repo_root"
    cd "$repo_root"

    if [ -z "$name" ]; then
        usage_error "--name is required"
    fi
    case "$name" in
        ''|.|..) usage_error "--name '$name' is reserved";;
        *[!A-Za-z0-9._-]*) usage_error "--name '$name' may contain only letters, digits, dot, underscore, or hyphen";;
    esac
    if [ -z "$description" ]; then
        description="$name"
    fi
    # results.tsv is tab-delimited and the report is a markdown table: a tab, newline, or pipe
    # in the description would corrupt one or the other.
    description="$(printf '%s' "$description" | tr -d '\r' | tr '\t\n|' '   ')"

    if [ -d "$session/mutations/$name" ] \
        || awk -F'\t' -v n="$name" '$1 == n { found = 1 } END { exit !found }' "$session/results.tsv"; then
        die "a mutation named '$name' already exists in this session" 2
    fi

    # A mutation that was never actually applied would run the pristine suite, come back green,
    # and be filed as a survivor — a false finding. Refuse it.
    local mutated=() rel
    while IFS= read -r rel; do
        if [ -z "$rel" ]; then
            continue
        fi
        if ! cmp -s "$session/backup/$rel" "$repo_root/$rel"; then
            mutated+=("$rel")
        fi
    done < "$session/targets"
    if [ "${#mutated[@]}" -eq 0 ]; then
        echo "error: no target file differs from the backup — no mutation is applied." >&2
        echo "       Edit one of the files in $session/targets, then re-run." >&2
        exit 3
    fi

    local mut_dir="$session/mutations/$name"
    mkdir -p "$mut_dir/files"

    # Preserve the mutated sources and a readable diff before running anything, so the
    # reproduction survives even a crash mid-suite.
    for rel in "${mutated[@]}"; do
        mkdir -p "$mut_dir/files/$(dirname -- "$rel")"
        cp -p "$repo_root/$rel" "$mut_dir/files/$rel"
    done
    : > "$mut_dir/mutation.patch"
    for rel in "${mutated[@]}"; do
        diff -u "$session/backup/$rel" "$repo_root/$rel" >> "$mut_dir/mutation.patch" || true
    done

    {
        echo "#!/usr/bin/env bash"
        echo "# Reproduce mutation '$name': $description"
        echo "# WARNING: this re-applies the mutation and leaves the tree broken."
        echo "# To restore afterwards, copy the backup back — never 'git checkout --':"
        for rel in "${mutated[@]}"; do
            echo "#   cp $(printf '%q' "$session/backup/$rel") $(printf '%q' "$repo_root/$rel")"
        done
        echo "set -euo pipefail"
        echo "cd $(printf '%q' "$repo_root")"
        for rel in "${mutated[@]}"; do
            echo "cp $(printf '%q' "$mut_dir/files/$rel") $(printf '%q' "$repo_root/$rel")"
        done
        printf '%s\n' "$test_cmd"
    } > "$mut_dir/repro.sh"
    chmod +x "$mut_dir/repro.sh" 2>/dev/null || true

    local started ended elapsed rc=0
    started="$(date +%s)"
    run_with_timeout "$timeout_secs" "$test_cmd" "$mut_dir/test.log" || rc=$?
    ended="$(date +%s)"
    elapsed=$((ended - started))

    local first result rc2=0 second="" deciding_log="$mut_dir/test.log"
    first="$(classify_rc "$rc")"
    case "$first" in
        green)
            result="survived";;
        harness)
            result="error";;
        timedout)
            # A timed-out suite proves nothing, and an intermittent hang reads as a catch and
            # hides a survivor. Always re-run once before classifying.
            echo "note: mutation '$name' timed out after ${timeout_secs}s — re-running once." >&2
            run_with_timeout "$timeout_secs" "$test_cmd" "$mut_dir/test.rerun.log" || rc2=$?
            second="$(classify_rc "$rc2")"
            deciding_log="$mut_dir/test.rerun.log"
            if [ "$second" = "timedout" ]; then
                result="timeout"
            else
                # The first run never finished, so neither outcome is proven either way.
                result="flaky"
            fi;;
        red)
            result="caught"
            if [ "$rerun_caught" -eq 1 ]; then
                run_with_timeout "$timeout_secs" "$test_cmd" "$mut_dir/test.rerun.log" || rc2=$?
                second="$(classify_rc "$rc2")"
                case "$second" in
                    green)    result="flaky";;
                    timedout) result="flaky";;
                    harness)  result="error";;
                esac
            fi;;
    esac

    local signature="$TSV_NONE"
    if [ "$result" = "caught" ] || [ "$result" = "flaky" ] || [ "$result" = "error" ]; then
        signature="$(failure_signature "$deciding_log")"
    fi

    # Restore, then prove it worked. The trap stays armed throughout; trap_restore disarms
    # itself once the copy-back has happened.
    trap_restore

    # Record the observed result BEFORE any further check can abort: the suite ran and was
    # classified, and discarding that would be exactly the silent omission this tool exists
    # to prevent.
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$result" "$elapsed" "$signature" "$description" \
        >> "$session/results.tsv"

    local drift
    if ! drift="$(verify_targets_match_backup "$session" "$repo_root")"; then
        echo "error: restore failed — these target files still differ from the backup:" >&2
        while IFS= read -r rel; do
            if [ -n "$rel" ]; then
                echo "  $rel" >&2
            fi
        done <<< "$drift"
        echo "       Restore manually with: cp \"$session/backup/<path>\" \"$repo_root/<path>\"" >&2
        exit 5
    fi

    echo "RESULT=$result"
    echo "SECONDS=$elapsed"
    echo "RESTORED=yes"

    # Nothing outside the target set may have changed. Those files are not backed up and will
    # not be restored, so a verdict computed against them describes a tree nobody intended.
    # Checked AFTER the restore, so the mutation's own edits are back to the reference and any
    # remaining drift is either the caller editing a non-target or the suite writing one.
    local state=0
    compare_to_reference "$session" "$repo_root" "$session/porcelain.run" || state=$?
    if [ "$state" -eq 2 ] || { [ "$state" -eq 1 ] && [ "$allow_artifacts" -eq 0 ]; }; then
        echo "error: the working tree changed outside the target set during '$name':" >&2
        printf '%s' "$DRIFT_TEXT" | sed 's/^/  /' >&2
        echo "       Only files listed in $session/targets are backed up and restored, so the" >&2
        echo "       result above was measured against a tree that is not the reference." >&2
        echo "       Revert the change (or re-run 'begin' with --allow-test-artifacts if these" >&2
        echo "       are test artifacts) before continuing the campaign." >&2
        exit 5
    fi

    # "Green again before the next mutation, so failures cannot cascade."
    if [ "$verify_green" -eq 1 ]; then
        local grc=0
        run_with_timeout "$timeout_secs" "$test_cmd" "$mut_dir/green.log" || grc=$?
        if [ "$grc" -eq 0 ]; then
            echo "GREEN_AGAIN=yes"
        else
            echo "GREEN_AGAIN=no"
            echo "error: the tree was restored byte-identically, but the suite is not green" >&2
            echo "       after '$name' (exit $grc). Later results would cascade from this." >&2
            echo "       Output: $mut_dir/green.log" >&2
            exit 6
        fi
    fi
}

# --- report -----------------------------------------------------------------

render_report() {
    local session="$1" banner="$2"
    local repo_root test_cmd rerun_caught verify_green base
    repo_root="$(read_meta "$session" repo_root)"
    test_cmd="$(read_meta "$session" test_cmd)"
    rerun_caught="$(read_meta "$session" rerun_caught)"
    verify_green="$(read_meta "$session" verify_green)"
    base="$(read_meta "$session" base)"

    local total=0 caught=0 survived=0 flaky=0 timedout=0 errored=0
    local name result elapsed signature description shown
    echo "# Mutation test report"
    echo
    if [ -n "$banner" ]; then
        echo "> **$banner**"
        echo ">"
        echo "> Every verdict below came from a campaign whose final state could not be proven."
        echo "> Treat the whole table as inconclusive until the tree is reconciled."
        echo
    fi
    echo "- Repository: \`$repo_root\`"
    if [ -n "$base" ]; then
        echo "- Base: \`$base\`"
    fi
    echo "- Test command: \`$test_cmd\`"
    echo "- Targets: $(wc -l < "$session/targets" | tr -d ' ') file(s)"
    echo "- Session: \`$session\`"
    echo
    echo "| Mutation | Result | Seconds | Failure signal | What it broke |"
    echo "|---|---|---|---|---|"
    while IFS=$'\t' read -r name result elapsed signature description; do
        if [ -z "$name" ]; then
            continue
        fi
        total=$((total + 1))
        case "$result" in
            caught) caught=$((caught + 1));;
            survived) survived=$((survived + 1));;
            flaky) flaky=$((flaky + 1));;
            timeout) timedout=$((timedout + 1));;
            error) errored=$((errored + 1));;
        esac
        if [ "$signature" = "$TSV_NONE" ]; then
            case "$result" in
                caught|flaky|error) shown="_none captured_";;
                *) shown="—";;
            esac
        else
            shown="$signature"
        fi
        echo "| \`$name\` | $result | $elapsed | $shown | $description |"
    done < "$session/results.tsv"
    if [ "$total" -eq 0 ]; then
        echo "| _(none yet)_ | | | | |"
    fi
    echo
    echo "**$caught caught, $survived survived** — inconclusive: $flaky flaky, $timedout timed out, $errored harness errors ($total total)."
    echo

    if [ "$((survived + flaky + timedout + errored))" -gt 0 ]; then
        echo "## Needs attention"
        echo
        while IFS=$'\t' read -r name result elapsed signature description; do
            if [ -z "$name" ]; then
                continue
            fi
            if [ "$signature" = "$TSV_NONE" ]; then
                signature="none captured"
            fi
            case "$result" in
                survived)
                    echo "- **\`$name\` survived** — $description"
                    echo "  The suite passed against this break. Either a test is missing, or the"
                    echo "  behaviour is genuinely untestable at this layer and the honest outcome is a"
                    echo "  documented gap rather than a new test."
                    echo "  Reproduce: \`bash $(printf '%q' "$session/mutations/$name/repro.sh")\` (re-applies the mutation and leaves the tree broken; restore with the \`cp\` line in its header)"
                    echo "  Diff: \`$session/mutations/$name/mutation.patch\`";;
                flaky)
                    echo "- **\`$name\` was flaky — inconclusive** — $description"
                    echo "  The two runs disagreed, so the outcome is not attributable to the break."
                    echo "  Treat as unproven, not as a catch. Signal: $signature"
                    echo "  Reproduce: \`bash $(printf '%q' "$session/mutations/$name/repro.sh")\`"
                    echo "  Logs: \`$session/mutations/$name/test.log\`, \`$session/mutations/$name/test.rerun.log\`";;
                timeout)
                    echo "- **\`$name\` timed out — inconclusive** — $description"
                    echo "  The suite never finished on either attempt, so nothing was proven."
                    echo "  Reproduce: \`bash $(printf '%q' "$session/mutations/$name/repro.sh")\`";;
                error)
                    echo "- **\`$name\` could not be run — inconclusive** — $description"
                    echo "  The test command itself failed to execute, so the code was never tested."
                    echo "  Signal: $signature. Log: \`$session/mutations/$name/test.log\`";;
            esac
        done < "$session/results.tsv"
        echo
    fi

    if [ "$caught" -gt 0 ]; then
        echo "> Check the failure signal on each caught row against the behaviour the mutation"
        echo "> targeted — a mutation that trips a *different* assertion is not coverage of what"
        echo "> it broke. Full output is in \`$session/mutations/<name>/test.log\`."
        echo
    fi
    if [ "$total" -gt 0 ] && [ "$caught" -eq 0 ] && [ "$survived" -gt 0 ]; then
        echo "> **No mutation was caught by any run.** A green baseline proves the suite passes;"
        echo "> it does not prove the suite can fail. Confirm the test command's exit code is"
        echo "> failure-sensitive (a piped command without \`pipefail\` always exits 0) before"
        echo "> treating these survivors as findings."
        echo
    fi
    if [ "$rerun_caught" -eq 0 ] && [ "$caught" -gt 0 ]; then
        echo "> Caught results were not re-confirmed (\`--rerun-caught\` was off). On a suite with"
        echo "> known intermittency a flaky failure reads as a catch and hides a survivor."
        echo
    fi
    if [ "$verify_green" -eq 0 ] && [ "$total" -gt 1 ]; then
        echo "> The suite was not re-run between mutations (\`--verify-green\` was off), so a"
        echo "> failure introduced by one mutation could in principle cascade into later rows."
        echo "> The closing check below covers the campaign as a whole, not each step."
        echo
    fi
}

# --- finish -----------------------------------------------------------------

cmd_finish() {
    local session="" allow_override="" final_check=1
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --session) need_value "$1" "$#"; session="$2"; shift 2;;
            --allow-test-artifacts) allow_override=1; shift;;
            --no-final-check) final_check=0; shift;;
            -h|--help) usage; exit 0;;
            *) usage_error "unknown argument: $1";;
        esac
    done
    if [ -z "$session" ]; then
        usage_error "--session is required"
    fi
    session="$(absolutize "$session" "$PWD")"
    require_session "$session"

    local repo_root test_cmd timeout_secs allow_artifacts
    repo_root="$(read_meta "$session" repo_root)"
    test_cmd="$(read_meta "$session" test_cmd)"
    timeout_secs="$(read_meta "$session" timeout)"
    allow_artifacts="$(read_meta "$session" allow_test_artifacts)"
    if [ -n "$allow_override" ]; then
        allow_artifacts=1
    fi
    require_matching_repo "$repo_root"

    # Verify FIRST, so the report can be banner-marked if its verdicts came from a campaign
    # whose end state cannot be proven. "Any step unverified => inconclusive" has to reach the
    # table, not just a line underneath it.
    local files_ok=1 drift rel
    if ! drift="$(verify_targets_match_backup "$session" "$repo_root")"; then
        files_ok=0
    fi
    local state=0
    compare_to_reference "$session" "$repo_root" "$session/porcelain.final" || state=$?

    local verified=""
    if [ "$files_ok" -eq 1 ] && [ "$state" -eq 0 ]; then
        verified="yes"
    elif [ "$files_ok" -eq 1 ] && [ "$state" -eq 1 ] && [ "$allow_artifacts" -eq 1 ]; then
        verified="partial"
    else
        verified="no"
    fi

    local banner=""
    if [ "$verified" = "no" ]; then
        banner="UNVERIFIED — the working tree could not be proven to match the reference"
    fi
    render_report "$session" "$banner"

    echo "## Tree verification"
    echo
    if [ "$files_ok" -eq 1 ]; then
        echo "- Target files byte-identical to backup: **yes** (\`cmp\` per file)"
    else
        echo "- Target files byte-identical to backup: **NO**"
        while IFS= read -r rel; do
            if [ -n "$rel" ]; then
                echo "  - \`$rel\`"
            fi
        done <<< "$drift"
    fi
    case "$state" in
        0) echo "- Rest of the working tree unchanged: **yes**";;
        1) echo "- Rest of the working tree unchanged: **untracked-only drift**";;
        *) echo "- Rest of the working tree unchanged: **NO**";;
    esac
    if [ -n "$DRIFT_TEXT" ]; then
        printf '%s' "$DRIFT_TEXT" | sed 's/^/  - `/; s/$/`/'
    fi
    echo
    echo "TREE_VERIFIED=$verified"

    # A closing suite run: byte-identical files prove the restore, this proves the tree the
    # user is left with is actually green, so nothing cascades out of the campaign. It is
    # reported INDEPENDENTLY of TREE_VERIFIED — a red suite on a provably restored tree is an
    # environment problem, not a restore problem, and telling the user to restore would send
    # them chasing something that is not broken.
    local suite_ok=1
    if [ "$final_check" -eq 1 ] && [ "$verified" != "no" ]; then
        local frc=0
        run_with_timeout "$timeout_secs" "$test_cmd" "$session/final.log" || frc=$?
        if [ "$frc" -eq 0 ]; then
            echo "FINAL_SUITE=green"
        else
            suite_ok=0
            echo "FINAL_SUITE=red"
        fi
    elif [ "$final_check" -eq 0 ]; then
        echo "FINAL_SUITE=skipped-by-request"
    else
        echo "FINAL_SUITE=skipped-tree-unverified"
    fi
    echo

    case "$verified" in
        yes|partial)
            if [ "$verified" = "partial" ]; then
                echo "Target files are byte-identical and no TRACKED file drifted; untracked test"
                echo "artifacts were forgiven by --allow-test-artifacts."
            fi
            if [ "$suite_ok" -eq 0 ]; then
                echo "The tree IS restored — do not restore anything. The suite is nonetheless red"
                echo "(\`$session/final.log\`), which points at the environment rather than at this"
                echo "campaign. Investigate before trusting the results above."
            fi
            echo "Session artifacts (backups, mutated sources, repro scripts) live in \`$session\`."
            echo "They are needed by every \`Reproduce:\` command above; the default location is"
            echo "temporary. Delete with: rm -rf \"$session\""
            if [ "$suite_ok" -eq 0 ]; then
                return 6
            fi
            return 0;;
        *)
            echo "Restore manually by copying from the backup — never \`git checkout --\`:"
            echo "  cp \"$session/backup/<path>\" \"$repo_root/<path>\""
            return 5;;
    esac
}

cmd_status() {
    local session=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --session) need_value "$1" "$#"; session="$2"; shift 2;;
            -h|--help) usage; exit 0;;
            *) usage_error "unknown argument: $1";;
        esac
    done
    if [ -z "$session" ]; then
        usage_error "--session is required"
    fi
    session="$(absolutize "$session" "$PWD")"
    require_session "$session"
    render_report "$session" ""
    # Deliberately not TREE_VERIFIED=... — `status` verifies nothing, and emitting that key
    # with an extra value invites a consumer to treat an unverified campaign as a verified one.
    echo "VERIFICATION=not-run"
}

# --- dispatch ---------------------------------------------------------------

if [ "$#" -eq 0 ]; then
    usage_error ""
fi
SUBCOMMAND="$1"; shift
case "$SUBCOMMAND" in
    begin) cmd_begin "$@";;
    run) cmd_run "$@";;
    # Called plainly so `set -e` stays in force inside the function: putting it on the left of
    # `||` would silence every unchecked failure in the one verb whose job is proving things.
    # errexit propagates its `return 5` / `return 6` as the script's exit code.
    finish) cmd_finish "$@";;
    status) cmd_status "$@";;
    -h|--help) usage; exit 0;;
    *) usage_error "unknown subcommand: $SUBCOMMAND";;
esac
