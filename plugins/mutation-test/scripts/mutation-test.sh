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
#   mutation-test.sh begin  --test-cmd <cmd> (--base <branch> | --file <path> ...) [options]
#   mutation-test.sh run    --session <dir> --name <name> [--description <text>]
#   mutation-test.sh finish --session <dir> [--allow-test-artifacts] [--no-final-check]
#   mutation-test.sh status --session <dir>
#
# Lifecycle:
#   begin   Refuse a dirty tree, resolve target files, copy them to a backup OUTSIDE the
#           repo, prove the suite is green, then snapshot `git status --porcelain` (after
#           the baseline run, so the suite's own caches are not mistaken for drift).
#   run     (caller has already edited the source) Save the mutated files for reproduction,
#           run the suite under a timeout, classify the result, then ALWAYS restore by
#           copying the backup back — never `git checkout`/`restore`/`stash`, which would
#           silently revert uncommitted work and leave the run looking green.
#   finish  Prove the tree is byte-identical to the backup, re-run the suite to prove it is
#           green again, and print the report. A run that cannot prove this is a failed run.
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
#   3  baseline suite is not green (begin), or no mutation was applied (run)
#   4  dirty working tree without --allow-dirty
#   5  tree verification failed — the working tree does NOT match the backup
#
# IMPORTANT: on ANY non-zero exit from `run`, verify the working tree before continuing.
# `run` restores from the backup on every path it can, but the caller applies the mutation
# before `run` is ever invoked, so a failure in the caller's own edit step is outside this
# script's reach.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
    cat <<USAGE
usage: $SCRIPT_NAME begin  --test-cmd <cmd> (--base <branch> | --file <path> [--file <path>...]) [options]
       $SCRIPT_NAME run    --session <dir> --name <name> [--description <text>]
       $SCRIPT_NAME finish --session <dir> [--allow-test-artifacts] [--no-final-check]
       $SCRIPT_NAME status --session <dir>

begin options:
  --test-cmd <cmd>        Shell command that runs the suite. Required. Exit 0 == green.
  --base <branch>         Target the files changed vs <branch> (git diff --name-only <branch>...HEAD).
  --file <path>           Target an explicit file. Repeatable. Combines with --base.
  --files-from <listfile> Target every path listed (one per line) in <listfile>.
  --exclude <glob>        Drop resolved targets matching <glob>. Repeatable. Every exclusion
                          is reported, never silent.
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
                          the final verification. Tracked-file drift always fails. Also accepted
                          by 'finish', so a campaign need not be re-run to set it.

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

die() { echo "error: $*" >&2; exit "${2:-1}"; }

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
    local p="$1"
    while [ -n "$p" ] && [ ! -d "$p" ]; do
        local parent
        parent="$(dirname "$p")"
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
    d="$(dirname "$f")"
    b="$(basename "$f")"
    printf '%s%s' "$( cd "$d" && git rev-parse --show-prefix )" "$b"
}

# Make a possibly-relative path absolute against a given directory. Handles Windows drive
# letters so a C:/... path from git is not treated as relative.
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
classify_rc() {
    case "$1" in
        0) echo green;;
        124|137) echo timedout;;
        125|126|127) echo harness;;
        *) echo red;;
    esac
}

# Pull the first line that looks like a failing assertion out of a suite log, so the report can
# say WHICH assertion fired. A mutation that trips an unrelated assertion is not coverage of
# the behaviour it targeted, and a pass/fail column cannot show that.
failure_signature() {
    local log="$1" sig=""
    if [ -f "$log" ]; then
        sig="$(grep -m1 -aE '(FAILED|FAIL:|AssertionError|Assertion.?[Ff]ailed|assert |^not ok|Expected .* (but|to)|Traceback|panic:|error:|ERROR:|✗|✘)' "$log" 2>/dev/null || true)"
    fi
    # Tabs would corrupt the TSV; pipes would add a column to the report's markdown table.
    printf '%s' "$sig" | tr '\t\n|' '   ' | sed 's/^[[:space:]]*//' | cut -c1-110
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
restore_from_backup() {
    local session="$1" repo_root="$2" rel failed=0
    while IFS= read -r rel; do
        if [ -z "$rel" ]; then
            continue
        fi
        if ! mkdir -p "$repo_root/$(dirname "$rel")" 2>/dev/null; then
            echo "restore: cannot create directory for '$rel'" >&2
            failed=1
            continue
        fi
        if ! cp -p "$session/backup/$rel" "$repo_root/$rel" 2>/dev/null; then
            echo "restore: FAILED to restore '$rel'" >&2
            failed=1
        fi
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
                # `|| [ -n "$line" ]` keeps a final entry that has no trailing newline.
                while IFS= read -r line || [ -n "$line" ]; do
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
    if [ -n "$(git status --porcelain)" ]; then
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
        # -z with core.quotePath=false: otherwise git returns a quoted, octal-escaped path for
        # any non-ASCII name and the file is silently dropped from the campaign.
        while IFS= read -r -d '' f; do
            if [ -n "$f" ]; then
                candidates+=("$f")
            fi
        done < <(git -c core.quotePath=false diff --name-only -z "$base...HEAD")
    fi
    for f in ${explicit_files[@]+"${explicit_files[@]}"}; do
        local abs
        abs="$(absolutize "$f" "$invocation_cwd")"
        if [ ! -e "$abs" ]; then
            die "target '$f' does not exist"
        fi
        if [ "$(toplevel_of "$(dirname "$abs")")" != "$repo_root" ]; then
            die "target '$f' is outside the repository at $repo_root"
        fi
        candidates+=("$(repo_relative_path "$abs")")
    done

    cd "$repo_root"

    # Drop duplicates, non-files, symlinks, and --exclude matches. Every drop is announced:
    # a silent cap reads as "covered everything" when it did not.
    local targets=() c seen dup ex
    for c in ${candidates[@]+"${candidates[@]}"}; do
        dup=0
        for seen in ${targets[@]+"${targets[@]}"}; do
            if [ "$seen" = "$c" ]; then
                dup=1
                break
            fi
        done
        if [ "$dup" -eq 1 ]; then
            continue
        fi
        dup=0
        for ex in ${excludes[@]+"${excludes[@]}"}; do
            # shellcheck disable=SC2254
            case "$c" in
                $ex) echo "note: excluding '$c' (matches --exclude '$ex')" >&2; dup=1; break;;
            esac
        done
        if [ "$dup" -eq 1 ]; then
            continue
        fi
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
        case "$c" in
            *[Tt]est*|*[Ss]pec*|*.md|*.json|*.lock|*.txt|*.snap)
                echo "note: '$c' looks like a test, doc, or data file — mutating it proves nothing about the change. Use --exclude to drop it." >&2;;
        esac
        targets+=("$c")
    done
    if [ "${#targets[@]}" -eq 0 ]; then
        die "no mutable target files resolved"
    fi

    # The session lives OUTSIDE the repo on purpose: a backup inside the working tree would
    # show up in `git status --porcelain` and corrupt the very check that proves the tree was
    # restored. Check BEFORE creating, so a rejected path leaves nothing behind.
    if [ -n "$session_dir" ]; then
        local probe
        probe="$(nearest_existing_dir "$(absolutize "$session_dir" "$invocation_cwd")")"
        if [ "$(toplevel_of "$probe")" = "$repo_root" ]; then
            die "--session-dir must be outside the repository (it would perturb git status)"
        fi
        session_dir="$(absolutize "$session_dir" "$invocation_cwd")"
        if [ -e "$session_dir/targets" ]; then
            die "'$session_dir' already holds a mutation-test session. Pick a fresh directory — reusing one would re-baseline against whatever is currently on disk."
        fi
        mkdir -p "$session_dir"
        chmod 700 "$session_dir" 2>/dev/null || true
        session_dir="$(cd "$session_dir" && pwd)"
    else
        session_dir="$(mktemp -d "${TMPDIR:-/tmp}/mutation-test-XXXXXX")"
        if [ "$(toplevel_of "$session_dir")" = "$repo_root" ]; then
            die "TMPDIR resolves inside the repository; pass --session-dir pointing outside it"
        fi
    fi

    mkdir -p "$session_dir/meta" "$session_dir/backup" "$session_dir/mutations"
    printf '%s' "$repo_root"       > "$session_dir/meta/repo_root"
    printf '%s' "$test_cmd"        > "$session_dir/meta/test_cmd"
    printf '%s' "$timeout_secs"    > "$session_dir/meta/timeout"
    printf '%s' "$rerun_caught"    > "$session_dir/meta/rerun_caught"
    printf '%s' "$verify_green"    > "$session_dir/meta/verify_green"
    printf '%s' "$allow_artifacts" > "$session_dir/meta/allow_test_artifacts"
    printf '%s' "$base"            > "$session_dir/meta/base"
    : > "$session_dir/results.tsv"

    local t
    printf '%s\n' "${targets[@]}" > "$session_dir/targets"
    for t in "${targets[@]}"; do
        mkdir -p "$session_dir/backup/$(dirname "$t")"
        cp -p "$repo_root/$t" "$session_dir/backup/$t"
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
        case "$(classify_rc "$rc")" in
            timedout) echo "error: baseline suite did not finish within ${timeout_secs}s. Raise --timeout or speed up the suite." >&2;;
            harness)  echo "error: baseline test command could not be run (exit $rc). Check --test-cmd." >&2;;
            *)        echo "error: baseline suite is not green (exit $rc). Fix the suite before mutating." >&2;;
        esac
        echo "       Output: $session_dir/baseline.log" >&2
        tail -20 "$session_dir/baseline.log" >&2 || true
        echo "BASELINE=red"
        exit 3
    fi

    # Snapshot porcelain AFTER the baseline run, so caches and coverage files the suite itself
    # creates are part of the reference state rather than drift attributed to the campaign.
    git status --porcelain > "$session_dir/porcelain.baseline"

    echo "BASELINE=green"
}

# --- run --------------------------------------------------------------------

cmd_run() {
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
    if [ ! -d "$session" ]; then
        die "session directory '$session' does not exist"
    fi
    if [ ! -f "$session/targets" ]; then
        die "'$session' is not a mutation-test session (no targets file)"
    fi

    local repo_root test_cmd timeout_secs rerun_caught verify_green
    repo_root="$(read_meta "$session" repo_root)"
    test_cmd="$(read_meta "$session" test_cmd)"
    timeout_secs="$(read_meta "$session" timeout)"
    rerun_caught="$(read_meta "$session" rerun_caught)"
    verify_green="$(read_meta "$session" verify_green)"
    if [ ! -d "$repo_root" ]; then
        die "recorded repo root '$repo_root' no longer exists"
    fi
    if [ "$(toplevel_of "$repo_root")" != "$repo_root" ]; then
        die "recorded repo root '$repo_root' is no longer a git repository"
    fi
    cd "$repo_root"

    # The caller mutated the tree BEFORE calling us, so arm the restore now — every validation
    # below this line can fail, and none of them may leave a mutation behind.
    arm_restore_trap "$session" "$repo_root"

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
    description="$(printf '%s' "$description" | tr '\t\n|' '   ')"

    if [ -d "$session/mutations/$name" ] \
        || { [ -f "$session/results.tsv" ] && cut -f1 "$session/results.tsv" | grep -Fxq -- "$name"; }; then
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
        mkdir -p "$mut_dir/files/$(dirname "$rel")"
        cp -p "$repo_root/$rel" "$mut_dir/files/$rel"
    done
    : > "$mut_dir/mutation.patch"
    for rel in "${mutated[@]}"; do
        diff -u "$session/backup/$rel" "$repo_root/$rel" >> "$mut_dir/mutation.patch" || true
    done
    printf '%s' "$description" > "$mut_dir/description"

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

    local first result rc2=0 second=""
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
            if [ "$second" = "timedout" ]; then
                result="timeout"
            else
                # First run never finished, so neither outcome is proven either way.
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

    local signature=""
    if [ "$result" = "caught" ] || [ "$result" = "flaky" ] || [ "$result" = "error" ]; then
        signature="$(failure_signature "$mut_dir/test.log")"
    fi

    # Restore, then prove it worked, and only then record. The trap stays armed throughout;
    # trap_restore disarms itself once the copy-back has happened.
    trap_restore

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

    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$result" "$elapsed" "$signature" "$description" \
        >> "$session/results.tsv"
    echo "RESULT=$result"
    echo "SECONDS=$elapsed"
    echo "RESTORED=yes"

    # "Green again before the next mutation, so failures cannot cascade."
    if [ "$verify_green" -eq 1 ]; then
        local grc=0
        run_with_timeout "$timeout_secs" "$test_cmd" "$mut_dir/green.log" || grc=$?
        if [ "$grc" -eq 0 ]; then
            echo "GREEN_AGAIN=yes"
        else
            echo "GREEN_AGAIN=no"
            echo "error: the suite is not green after restoring '$name' (exit $grc)." >&2
            echo "       Later results would cascade from this. Output: $mut_dir/green.log" >&2
            exit 5
        fi
    fi
}

# --- report -----------------------------------------------------------------

render_report() {
    local session="$1"
    local repo_root test_cmd rerun_caught base
    repo_root="$(read_meta "$session" repo_root)"
    test_cmd="$(read_meta "$session" test_cmd)"
    rerun_caught="$(read_meta "$session" rerun_caught)"
    base="$(read_meta "$session" base)"

    local total=0 caught=0 survived=0 flaky=0 timedout=0 errored=0
    local name result elapsed signature description
    echo "# Mutation test report"
    echo
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
        echo "| \`$name\` | $result | $elapsed | ${signature:-—} | $description |"
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
            case "$result" in
                survived)
                    echo "- **\`$name\` survived** — $description"
                    echo "  The suite passed against this break. Either a test is missing, or the"
                    echo "  behaviour is genuinely untestable at this layer and the honest outcome is a"
                    echo "  documented gap rather than a new test."
                    echo "  Reproduce: \`bash $(printf '%q' "$session/mutations/$name/repro.sh")\` (re-applies the mutation and leaves the tree broken; restore with the \`cp\` line in its header)";;
                flaky)
                    echo "- **\`$name\` was flaky — inconclusive** — $description"
                    echo "  The two runs disagreed, so the outcome is not attributable to the break."
                    echo "  Treat as unproven, not as a catch. Signal: ${signature:-none captured}"
                    echo "  Reproduce: \`bash $(printf '%q' "$session/mutations/$name/repro.sh")\`";;
                timeout)
                    echo "- **\`$name\` timed out — inconclusive** — $description"
                    echo "  The suite never finished on either attempt, so nothing was proven."
                    echo "  Reproduce: \`bash $(printf '%q' "$session/mutations/$name/repro.sh")\`";;
                error)
                    echo "- **\`$name\` could not be run — inconclusive** — $description"
                    echo "  The test command itself failed to execute, so the code was never tested."
                    echo "  Signal: ${signature:-none captured}. Log: \`$session/mutations/$name/test.log\`";;
            esac
        done < "$session/results.tsv"
        echo
    fi

    if [ "$caught" -gt 0 ]; then
        echo "> Check the failure signal on each caught row. A mutation that trips an assertion"
        echo "> *other* than the one it targeted is not coverage of the behaviour it broke."
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
    if [ ! -d "$session" ]; then
        die "session directory '$session' does not exist"
    fi
    if [ ! -f "$session/targets" ]; then
        die "'$session' is not a mutation-test session (no targets file)"
    fi

    render_report "$session"

    local repo_root test_cmd timeout_secs allow_artifacts
    repo_root="$(read_meta "$session" repo_root)"
    test_cmd="$(read_meta "$session" test_cmd)"
    timeout_secs="$(read_meta "$session" timeout)"
    allow_artifacts="$(read_meta "$session" allow_test_artifacts)"
    if [ -n "$allow_override" ]; then
        allow_artifacts=1
    fi

    # Final verification. This is the step people drop, and dropping it is how a mutation ships.
    echo "## Tree verification"
    echo
    local files_ok=1 porcelain_ok=1 tracked_drift=0 drift rel
    if drift="$(verify_targets_match_backup "$session" "$repo_root")"; then
        echo "- Target files byte-identical to backup: **yes** (\`cmp\` per file)"
    else
        files_ok=0
        echo "- Target files byte-identical to backup: **NO**"
        while IFS= read -r rel; do
            if [ -n "$rel" ]; then
                echo "  - \`$rel\`"
            fi
        done <<< "$drift"
    fi

    ( cd "$repo_root" && git status --porcelain ) > "$session/porcelain.final"
    local delta
    delta="$(diff "$session/porcelain.baseline" "$session/porcelain.final" || true)"
    if [ -z "$delta" ]; then
        echo "- \`git status --porcelain\` unchanged: **yes**"
    else
        porcelain_ok=0
        echo "- \`git status --porcelain\` unchanged: **NO**"
        # Only untracked ('??') entries can be forgiven as test artifacts. Anything else is a
        # tracked file the campaign altered, which is exactly what must never be waved through.
        local entry
        while IFS= read -r rel; do
            case "$rel" in
                '< '*|'> '*)
                    entry="${rel:2}"
                    echo "  - \`$entry\`"
                    case "$entry" in
                        '?? '*) ;;
                        *) tracked_drift=1;;
                    esac;;
            esac
        done <<< "$delta"
    fi
    echo

    local verified=""
    if [ "$files_ok" -eq 1 ] && [ "$porcelain_ok" -eq 1 ]; then
        verified="yes"
    elif [ "$files_ok" -eq 1 ] && [ "$allow_artifacts" -eq 1 ] && [ "$tracked_drift" -eq 0 ]; then
        verified="partial"
    else
        verified="no"
    fi

    # A closing suite run: byte-identical files prove the restore, this proves the tree the
    # user is left with is actually green, so nothing cascades out of the campaign.
    if [ "$final_check" -eq 1 ] && [ "$verified" != "no" ]; then
        local frc=0
        run_with_timeout "$timeout_secs" "$test_cmd" "$session/final.log" || frc=$?
        if [ "$frc" -eq 0 ]; then
            echo "- Suite green again after the campaign: **yes**"
            echo "FINAL_SUITE=green"
        else
            echo "- Suite green again after the campaign: **NO** (exit $frc, \`$session/final.log\`)"
            echo "FINAL_SUITE=red"
            verified="no"
        fi
    else
        echo "FINAL_SUITE=skipped"
    fi
    echo

    echo "TREE_VERIFIED=$verified"
    case "$verified" in
        yes)
            echo
            echo "Session artifacts (backups, mutated sources, repro scripts) live in \`$session\`."
            echo "They are needed by every \`Reproduce:\` command above. Delete with: rm -rf \"$session\""
            return 0;;
        partial)
            echo
            echo "Target files are byte-identical and no TRACKED file drifted; untracked test"
            echo "artifacts were forgiven by --allow-test-artifacts."
            echo "Session artifacts live in \`$session\`. Delete with: rm -rf \"$session\""
            return 0;;
        *)
            echo
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
    if [ ! -d "$session" ]; then
        die "session directory '$session' does not exist"
    fi
    if [ ! -f "$session/targets" ]; then
        die "'$session' is not a mutation-test session (no targets file)"
    fi
    render_report "$session"
    # Deliberately not TREE_VERIFIED=... — `status` verifies nothing, and emitting that key
    # with a fourth value invites a consumer to treat an unverified campaign as a verified one.
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
    finish) rc=0; cmd_finish "$@" || rc=$?; exit "$rc";;
    status) cmd_status "$@";;
    -h|--help) usage; exit 0;;
    *) usage_error "unknown subcommand: $SUBCOMMAND";;
esac
