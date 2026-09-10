#!/usr/bin/env bash
# Mutation-test a change set: run a test suite against deliberately broken source and
# report which mutations SURVIVED (i.e. which tests pass against broken code).
#
# This script owns the mechanical, destructive, and verification steps — the ones that
# get dropped at step 9 of 12. It does NOT choose the mutations: the caller applies each
# mutation itself (semantic mutations grounded in what the change *claims* to do beat a
# generic operator sweep), then hands control back here to run, record, and restore.
#
# Usage:
#   mutation-test.sh begin  --test-cmd <cmd> (--base <branch> | --file <path> ...) [options]
#   mutation-test.sh run    --session <dir> --name <name> [--description <text>]
#   mutation-test.sh finish --session <dir>
#   mutation-test.sh status --session <dir>
#
# Lifecycle:
#   begin   Refuse a dirty tree, resolve target files, copy them to a backup OUTSIDE the
#           repo, snapshot `git status --porcelain`, and prove the suite is green.
#   run     (caller has already edited the source) Save the mutated files for reproduction,
#           run the suite under a timeout, classify caught/survived/flaky/timeout, then
#           ALWAYS restore by copying the backup back — never `git checkout`/`restore`/`stash`,
#           which would silently revert uncommitted work and leave the run looking green.
#   finish  Prove the tree is byte-identical to the backup and print the report. A run that
#           cannot prove this is a failed run.
#
# Exit codes:
#   0  success
#   1  general error (not a repo, missing session, bad target, ...)
#   2  usage error
#   3  baseline suite is not green (begin), or no mutation was applied (run)
#   4  dirty working tree without --allow-dirty
#   5  tree verification failed — the working tree does NOT match the backup

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
    cat >&2 <<USAGE
usage: $SCRIPT_NAME begin  --test-cmd <cmd> (--base <branch> | --file <path> [--file <path>...]) [options]
       $SCRIPT_NAME run    --session <dir> --name <name> [--description <text>]
       $SCRIPT_NAME finish --session <dir>
       $SCRIPT_NAME status --session <dir>

begin options:
  --test-cmd <cmd>        Shell command that runs the suite. Required. Exit 0 == green.
  --base <branch>         Target the files changed vs <branch> (git diff --name-only <branch>...HEAD).
  --file <path>           Target an explicit file. Repeatable. Combines with --base.
  --files-from <listfile> Target every path listed (one per line) in <listfile>.
  --timeout <seconds>     Per-run timeout. Default 600. A mutation that hangs is restored, not left.
  --session-dir <dir>     Where to keep the backup and artifacts. Must be OUTSIDE the repo.
                          Default: a fresh mktemp dir.
  --rerun-caught          Re-run every 'caught' result once to filter flaky failures. Use on any
                          suite with known intermittency — a flake reads as a catch and hides a
                          survivor. Timeouts are always re-run regardless of this flag.
  --allow-dirty           Proceed with uncommitted changes. The backup still protects them, but
                          you are acknowledging the baseline is not a known-good commit.
  --allow-test-artifacts  Let the suite leave untracked artifacts (caches, coverage) without
                          failing the final verification. Target files must still match exactly.

run options:
  --session <dir>         Session directory printed by 'begin'.
  --name <name>           Short identifier for this mutation. [A-Za-z0-9._-] only.
  --description <text>    What this mutation breaks, in the change's own terms.
USAGE
}

die() { echo "error: $*" >&2; exit "${2:-1}"; }

# --- shared helpers ---------------------------------------------------------

# The git toplevel of a directory, or empty if it isn't inside a repository. Used instead of
# string-comparing absolute paths: on Windows `pwd` yields /c/... while `git rev-parse` yields
# C:/..., so a textual prefix test would wrongly call every path "outside the repository".
toplevel_of() {
    ( cd "$1" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null ) || true
}

# Repo-relative path for an existing file, resolved through git so it works for absolute and
# relative inputs alike, from any subdirectory, on any platform.
repo_relative_path() {
    local f="$1" d b
    d="$(dirname "$f")"
    b="$(basename "$f")"
    printf '%s%s' "$( cd "$d" && git rev-parse --show-prefix )" "$b"
}

read_meta() {
    local session="$1" key="$2"
    [ -f "$session/meta/$key" ] || die "session at '$session' is missing meta/$key — not a mutation-test session?"
    cat "$session/meta/$key"
}

# Run a command string with a wall-clock timeout. Returns the command's exit code,
# or 124 if it was killed for exceeding the timeout (matching GNU timeout's convention).
run_with_timeout() {
    local secs="$1" cmd="$2" log="$3" rc=0
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 10 "$secs" bash -c "$cmd" >"$log" 2>&1 || rc=$?
        return "$rc"
    fi
    # Portable fallback for hosts without GNU coreutils (e.g. stock macOS).
    bash -c "$cmd" >"$log" 2>&1 &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$secs" ]; then
            kill -TERM "$pid" 2>/dev/null || true
            sleep 2
            kill -KILL "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid" || rc=$?
    return "$rc"
}

# Set by 'run' before it breaks anything. The EXIT trap fires after the function's locals
# are gone, so the restore paths have to live at global scope.
TRAP_SESSION=""
TRAP_REPO_ROOT=""

trap_restore() {
    [ -n "$TRAP_SESSION" ] || return 0
    restore_from_backup "$TRAP_SESSION" "$TRAP_REPO_ROOT"
}

# Copy every target file back from the backup. This is the ONLY restore mechanism:
# `git checkout -- <path>` would also discard uncommitted work in the same file and
# leave the campaign looking green, which is exactly the failure this script exists
# to prevent.
restore_from_backup() {
    local session="$1" repo_root="$2" rel
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        mkdir -p "$repo_root/$(dirname "$rel")"
        cp -p "$session/backup/$rel" "$repo_root/$rel"
    done < "$session/targets"
}

# Byte-compare every target file against its backup. Prints drifted paths, returns 1 on drift.
verify_targets_match_backup() {
    local session="$1" repo_root="$2" rel drift=0
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
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
    local rerun_caught=0 allow_dirty=0 allow_artifacts=0
    local explicit_files=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --test-cmd) test_cmd="${2:-}"; shift 2;;
            --base) base="${2:-}"; shift 2;;
            --file) explicit_files+=("${2:-}"); shift 2;;
            --files-from)
                local listfile="${2:-}" line
                [ -f "$listfile" ] || die "--files-from '$listfile' does not exist"
                while IFS= read -r line; do
                    [ -n "$line" ] && explicit_files+=("$line")
                done < "$listfile"
                shift 2;;
            --timeout) timeout_secs="${2:-}"; shift 2;;
            --session-dir) session_dir="${2:-}"; shift 2;;
            --rerun-caught) rerun_caught=1; shift;;
            --allow-dirty) allow_dirty=1; shift;;
            --allow-test-artifacts) allow_artifacts=1; shift;;
            -h|--help) usage; exit 0;;
            *) echo "unknown arg: $1" >&2; usage; exit 2;;
        esac
    done

    [ -n "$test_cmd" ] || { echo "error: --test-cmd is required" >&2; usage; exit 2; }
    printf '%s' "$timeout_secs" | grep -Eq '^[0-9]+$' || die "--timeout must be a whole number of seconds" 2
    [ "$timeout_secs" -gt 0 ] || die "--timeout must be greater than zero" 2
    if [ -z "$base" ] && [ "${#explicit_files[@]}" -eq 0 ]; then
        echo "error: give --base <branch>, --file <path>, or --files-from <listfile> to say what to mutate" >&2
        usage
        exit 2
    fi

    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"
    cd "$repo_root"

    # A dirty tree means the baseline is not a known-good state: a survivor could be an
    # artifact of uncommitted work rather than of the mutation.
    if ! git diff --quiet || ! git diff --cached --quiet; then
        if [ "$allow_dirty" -eq 0 ]; then
            echo "error: working tree is dirty. Mutation testing assumes a known-good baseline." >&2
            echo "       Commit or discard the changes, or pass --allow-dirty to acknowledge." >&2
            git status --short >&2
            exit 4
        fi
        echo "warning: proceeding with a dirty working tree (--allow-dirty)." >&2
    fi

    # Resolve target files.
    local candidates=() f
    if [ -n "$base" ]; then
        git rev-parse --verify --quiet "$base" >/dev/null \
            || die "--base '$base' is not a known ref. Fetch it first (git fetch origin $base)."
        while IFS= read -r f; do
            [ -n "$f" ] && candidates+=("$f")
        done < <(git diff --name-only "$base...HEAD")
    fi
    for f in ${explicit_files[@]+"${explicit_files[@]}"}; do
        # Normalize to a repo-relative path so backup/ mirrors the repo layout.
        [ -e "$f" ] || die "target '$f' does not exist"
        [ "$(toplevel_of "$(dirname "$f")")" = "$repo_root" ] \
            || die "target '$f' is outside the repository at $repo_root"
        candidates+=("$(repo_relative_path "$f")")
    done

    # Drop duplicates and paths that no longer exist (a diff lists deleted files too).
    local targets=() seen_list="" c
    for c in ${candidates[@]+"${candidates[@]}"}; do
        case "$seen_list" in
            *"|$c|"*) continue;;
        esac
        seen_list="$seen_list|$c|"
        if [ -f "$repo_root/$c" ]; then
            targets+=("$c")
        else
            echo "note: skipping '$c' (not a regular file in the working tree)" >&2
        fi
    done
    [ "${#targets[@]}" -gt 0 ] || die "no mutable target files resolved"

    # The session lives OUTSIDE the repo on purpose: a backup inside the working tree would
    # show up in `git status --porcelain` and corrupt the very check that proves the tree
    # was restored.
    if [ -n "$session_dir" ]; then
        mkdir -p "$session_dir"
        if [ "$(toplevel_of "$session_dir")" = "$repo_root" ]; then
            die "--session-dir must be outside the repository (it would perturb git status)"
        fi
        session_dir="$(cd "$session_dir" && pwd)"
    else
        session_dir="$(mktemp -d "${TMPDIR:-/tmp}/mutation-test-XXXXXX")"
    fi

    mkdir -p "$session_dir/meta" "$session_dir/backup" "$session_dir/mutations"
    printf '%s' "$repo_root"       > "$session_dir/meta/repo_root"
    printf '%s' "$test_cmd"        > "$session_dir/meta/test_cmd"
    printf '%s' "$timeout_secs"    > "$session_dir/meta/timeout"
    printf '%s' "$rerun_caught"    > "$session_dir/meta/rerun_caught"
    printf '%s' "$allow_artifacts" > "$session_dir/meta/allow_test_artifacts"
    printf '%s' "$base"            > "$session_dir/meta/base"
    : > "$session_dir/results.tsv"

    local t
    printf '%s\n' "${targets[@]}" > "$session_dir/targets"
    for t in "${targets[@]}"; do
        mkdir -p "$session_dir/backup/$(dirname "$t")"
        cp -p "$repo_root/$t" "$session_dir/backup/$t"
    done

    git status --porcelain > "$session_dir/porcelain.baseline"

    # Baseline: the suite must be green before anything is broken, or every later result
    # is meaningless.
    echo "Running baseline suite (timeout ${timeout_secs}s)..." >&2
    local rc=0
    run_with_timeout "$timeout_secs" "$test_cmd" "$session_dir/baseline.log" || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "error: baseline suite is not green (exit $rc). Fix the suite before mutating." >&2
        echo "       Output: $session_dir/baseline.log" >&2
        tail -20 "$session_dir/baseline.log" >&2 || true
        echo "BASELINE=red"
        exit 3
    fi

    echo "SESSION=$session_dir"
    echo "TARGETS=${#targets[@]}"
    echo "BASELINE=green"
}

# --- run --------------------------------------------------------------------

cmd_run() {
    local session="" name="" description=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --session) session="${2:-}"; shift 2;;
            --name) name="${2:-}"; shift 2;;
            --description) description="${2:-}"; shift 2;;
            -h|--help) usage; exit 0;;
            *) echo "unknown arg: $1" >&2; usage; exit 2;;
        esac
    done

    [ -n "$session" ] || { echo "error: --session is required" >&2; usage; exit 2; }
    [ -n "$name" ] || { echo "error: --name is required" >&2; usage; exit 2; }
    printf '%s' "$name" | grep -Eq '^[A-Za-z0-9._-]+$' \
        || die "--name '$name' must contain only letters, digits, dot, underscore, or hyphen" 2
    [ -d "$session" ] || die "session directory '$session' does not exist"
    [ -f "$session/targets" ] || die "'$session' is not a mutation-test session (no targets file)"
    [ -n "$description" ] || description="$name"
    # results.tsv is tab-delimited; a literal tab in the description would corrupt a row.
    description="$(printf '%s' "$description" | tr '\t\n' '  ')"

    local repo_root test_cmd timeout_secs rerun_caught
    repo_root="$(read_meta "$session" repo_root)"
    test_cmd="$(read_meta "$session" test_cmd)"
    timeout_secs="$(read_meta "$session" timeout)"
    rerun_caught="$(read_meta "$session" rerun_caught)"
    [ -d "$repo_root" ] || die "recorded repo root '$repo_root' no longer exists"
    cd "$repo_root"

    if [ -f "$session/results.tsv" ] \
        && cut -f1 "$session/results.tsv" | grep -Fxq "$name"; then
        die "a mutation named '$name' has already been recorded in this session" 2
    fi

    # A mutation that was never actually applied would run the pristine suite, come back
    # green, and be filed as a survivor — a false finding. Refuse it.
    local mutated=() rel
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
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

    # From here on the tree is broken. Restore on ANY exit path, including Ctrl-C, so a
    # mutation can never be left behind.
    TRAP_SESSION="$session"
    TRAP_REPO_ROOT="$repo_root"
    trap trap_restore EXIT INT TERM

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

    local result
    if [ "$rc" -eq 0 ]; then
        result="survived"
    elif [ "$rc" -eq 124 ]; then
        # A timed-out suite is not evidence of a catch — an intermittent hang reads as a
        # catch and hides a survivor. Always re-run a timeout once before classifying it.
        echo "note: mutation '$name' timed out after ${timeout_secs}s — re-running once." >&2
        local rc2=0
        run_with_timeout "$timeout_secs" "$test_cmd" "$mut_dir/test.rerun.log" || rc2=$?
        if [ "$rc2" -eq 124 ]; then
            result="timeout"
        elif [ "$rc2" -eq 0 ]; then
            result="survived"
        else
            result="caught"
        fi
    else
        result="caught"
        if [ "$rerun_caught" -eq 1 ]; then
            local rc2=0
            run_with_timeout "$timeout_secs" "$test_cmd" "$mut_dir/test.rerun.log" || rc2=$?
            if [ "$rc2" -eq 0 ]; then
                # Failed once, passed once, same mutation: the failure was not caused by the
                # mutation reliably, so this is not a catch.
                result="flaky"
            elif [ "$rc2" -eq 124 ]; then
                result="timeout"
            fi
        fi
    fi
    ended="$(date +%s)"
    elapsed=$((ended - started))

    trap - EXIT INT TERM
    TRAP_SESSION=""
    restore_from_backup "$session" "$repo_root"

    # Prove the restore worked before the next mutation is layered on top.
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

    printf '%s\t%s\t%s\t%s\n' "$name" "$result" "$elapsed" "$description" >> "$session/results.tsv"
    echo "RESULT=$result"
    echo "SECONDS=$elapsed"
    echo "RESTORED=yes"
}

# --- report -----------------------------------------------------------------

# Shared by 'finish' and 'status'. $2 = 1 to run the final verification.
render_report() {
    local session="$1" do_verify="$2"
    local repo_root test_cmd allow_artifacts rerun_caught base
    repo_root="$(read_meta "$session" repo_root)"
    test_cmd="$(read_meta "$session" test_cmd)"
    allow_artifacts="$(read_meta "$session" allow_test_artifacts)"
    rerun_caught="$(read_meta "$session" rerun_caught)"
    base="$(read_meta "$session" base)"

    local total=0 caught=0 survived=0 flaky=0 timedout=0
    local name result elapsed description
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
    echo "| Mutation | Result | Seconds | What it broke |"
    echo "|---|---|---|---|"
    while IFS=$'\t' read -r name result elapsed description; do
        [ -n "$name" ] || continue
        total=$((total + 1))
        case "$result" in
            caught) caught=$((caught + 1));;
            survived) survived=$((survived + 1));;
            flaky) flaky=$((flaky + 1));;
            timeout) timedout=$((timedout + 1));;
        esac
        echo "| \`$name\` | $result | $elapsed | $description |"
    done < <(cat "$session/results.tsv" 2>/dev/null || true)
    if [ "$total" -eq 0 ]; then
        echo "| _(none yet)_ | | | |"
    fi
    echo
    echo "**$caught caught, $survived survived, $flaky flaky, $timedout timed out** ($total total)."
    echo

    if [ "$((survived + flaky + timedout))" -gt 0 ]; then
        echo "## Needs attention"
        echo
        while IFS=$'\t' read -r name result elapsed description; do
            [ -n "$name" ] || continue
            case "$result" in
                survived)
                    echo "- **\`$name\` survived** — $description"
                    echo "  The suite passed against this break. Either a test is missing, or the"
                    echo "  behaviour is genuinely untestable at this layer and the honest outcome is a"
                    echo "  documented gap rather than a new test."
                    echo "  Reproduce: \`bash $session/mutations/$name/repro.sh\`";;
                flaky)
                    echo "- **\`$name\` was flaky** — $description"
                    echo "  Failed once and passed once against the same mutation, so the failure is not"
                    echo "  attributable to the break. Treat as unproven, not as a catch."
                    echo "  Reproduce: \`bash $session/mutations/$name/repro.sh\`";;
                timeout)
                    echo "- **\`$name\` timed out** — $description"
                    echo "  Inconclusive: the suite never finished, so nothing was proven either way."
                    echo "  Reproduce: \`bash $session/mutations/$name/repro.sh\`";;
            esac
        done < <(cat "$session/results.tsv" 2>/dev/null || true)
        echo
    fi

    if [ "$rerun_caught" -eq 0 ] && [ "$caught" -gt 0 ]; then
        echo "> Caught results were not re-confirmed (\`--rerun-caught\` was off). On a suite with"
        echo "> known intermittency a flaky failure reads as a catch and hides a survivor."
        echo
    fi

    [ "$do_verify" -eq 1 ] || return 0

    # Final verification. This is the step people drop, and dropping it is how a mutation ships.
    echo "## Tree verification"
    echo
    local files_ok=1 porcelain_ok=1 drift rel
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

    local porcelain_now
    porcelain_now="$(cd "$repo_root" && git status --porcelain)"
    if [ "$porcelain_now" = "$(cat "$session/porcelain.baseline")" ]; then
        echo "- \`git status --porcelain\` unchanged: **yes**"
    else
        porcelain_ok=0
        echo "- \`git status --porcelain\` unchanged: **NO**"
        diff <(cat "$session/porcelain.baseline") <(printf '%s\n' "$porcelain_now") \
            | sed 's/^/  /' || true
    fi
    echo

    if [ "$files_ok" -eq 1 ] && [ "$porcelain_ok" -eq 1 ]; then
        echo "TREE_VERIFIED=yes"
        return 0
    fi
    if [ "$files_ok" -eq 1 ] && [ "$allow_artifacts" -eq 1 ]; then
        echo "TREE_VERIFIED=partial (target files clean; untracked test artifacts allowed)"
        return 0
    fi
    echo "TREE_VERIFIED=no"
    echo
    echo "Restore manually by copying from the backup — never \`git checkout --\`:"
    echo "  cp \"$session/backup/<path>\" \"$repo_root/<path>\""
    return 5
}

cmd_finish() {
    local session=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --session) session="${2:-}"; shift 2;;
            -h|--help) usage; exit 0;;
            *) echo "unknown arg: $1" >&2; usage; exit 2;;
        esac
    done
    [ -n "$session" ] || { echo "error: --session is required" >&2; usage; exit 2; }
    [ -d "$session" ] || die "session directory '$session' does not exist"
    [ -f "$session/targets" ] || die "'$session' is not a mutation-test session (no targets file)"

    local rc=0
    render_report "$session" 1 || rc=$?
    exit "$rc"
}

cmd_status() {
    local session=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --session) session="${2:-}"; shift 2;;
            -h|--help) usage; exit 0;;
            *) echo "unknown arg: $1" >&2; usage; exit 2;;
        esac
    done
    [ -n "$session" ] || { echo "error: --session is required" >&2; usage; exit 2; }
    [ -d "$session" ] || die "session directory '$session' does not exist"
    [ -f "$session/targets" ] || die "'$session' is not a mutation-test session (no targets file)"
    render_report "$session" 0
}

# --- dispatch ---------------------------------------------------------------

[ "$#" -gt 0 ] || { usage; exit 2; }
SUBCOMMAND="$1"; shift
case "$SUBCOMMAND" in
    begin) cmd_begin "$@";;
    run) cmd_run "$@";;
    finish) cmd_finish "$@";;
    status) cmd_status "$@";;
    -h|--help) usage; exit 0;;
    *) echo "unknown subcommand: $SUBCOMMAND" >&2; usage; exit 2;;
esac
