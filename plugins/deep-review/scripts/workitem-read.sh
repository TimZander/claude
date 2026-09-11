#!/usr/bin/env bash
set -euo pipefail

# workitem-read.sh — Print an Azure DevOps work item's story fields as plain
# text, for /deep-review Step 1c to grade a diff against.
#
# USAGE — TWO FORMS, AND WHICH ONE YOU WANT DEPENDS ON WHO EXPORTS THE ORG:
#
#   # Constrained runner: the organization is already exported by whoever set
#   # the review up. Invoke the script BARE, with no assignment in front of it.
#   # An allow-rule of the form `Bash(bash <path>/workitem-read.sh:*)` matches a
#   # command that STARTS with `bash`; prefixing an assignment makes the command
#   # start with the assignment instead, and the rule no longer matches.
#   bash workitem-read.sh <id>
#
#   # Developer shell: nothing is exported, so set it inline from the ORG that
#   # resolve-pr.sh already reported.
#   DEEP_REVIEW_ADO_ORG=https://dev.azure.com/<org> bash workitem-read.sh <id>
#
# REQUIRES: `az` with the azure-devops extension, and Python 3.7 or newer on
# PATH as `python3`, `python`, or `py -3`. (3.7 for sys.stdout.reconfigure.)
#
# OUTPUT on stdout: a labelled block — id, type, state, title, then Description
# and Acceptance criteria. The two free-text fields are wrapped in an explicit
# untrusted-text fence, because a work item is writable by anyone with board
# access and its contents flow straight into a reviewing model's context.
# Errors go to stderr; a failure here is never fatal to a review — the caller
# reports "found but not fetchable" and carries on.
#
# WHY THIS EXISTS AT ALL, when `az boards work-item show` is one command.
#
# Because a constrained runner cannot safely allow `az`. `az`, like every
# argparse-based CLI, honours the LAST occurrence of a repeated option, so
# `--org <pinned> --org https://evil/x` satisfies any prefix allow-rule and
# ships the credential off-org. A reviewer running under such a rule therefore
# resolves a work item id and then reports it as unfetchable — the id is known
# and the story is still unreachable. This script is the same command behind a
# surface that CAN be allowed: one named script, one argument, and the
# organization taken from the environment rather than from anything the model
# writes.
#
# THE ENVIRONMENT IS THE CONTROL — but only where the caller cannot write the
# environment. Under an allow-rule the model cannot prepend an assignment (see
# above), so the org is fixed by whoever exported it. In an unconstrained shell
# the caller can set anything it likes, which is why the value is ALSO validated
# below against the only two URL shapes an ADO organization can have. The
# validation is what protects the credential on the path where no allow-rule is
# there to.
#
# NOT DERIVED FROM THE GIT REMOTE, though that would need no input at all:
# resolve-pr.sh owns remote parsing (ado_org_name / ado_org_url) and a second
# copy here is the drift this repo keeps removing. If that parsing is ever
# extracted into a shared library, deriving here becomes a one-line call and
# this variable can become a fallback rather than a requirement.

die() { printf 'workitem-read: %s\n' "$*" >&2; exit 1; }

TMPDIR_SELF=""
cleanup() { [ -n "$TMPDIR_SELF" ] && rm -rf "$TMPDIR_SELF"; return 0; }
trap cleanup EXIT INT TERM

[[ $# -eq 1 ]] || die 'usage: workitem-read.sh <work-item-id>  (org from $DEEP_REVIEW_ADO_ORG)'
WI_ID="$1"

# Same shape the central pipeline enforces on a PR id, and for a related
# reason: this value is interpolated into a command line. `^[0-9]+$` would
# accept `0100`, which names no work item, and an unbounded id is pointless.
[[ "$WI_ID" =~ ^[1-9][0-9]{0,9}$ ]] \
    || die "work item id must be 1-10 digits with no leading zero, got '${WI_ID}'"

ORG="${DEEP_REVIEW_ADO_ORG:-}"
[[ -n "$ORG" ]] \
    || die 'DEEP_REVIEW_ADO_ORG is not set. It is read from the environment, never from an argument, so that a caller cannot redirect the request to another organization.'

# An unexpanded pipeline macro arrives as a literal '$(Something)', '${Something}'
# or '`Something`': non-empty, so an emptiness check passes it, and the shape
# check below would reject it with a message about URL shape rather than about
# the variable that never expanded. Name the actual cause first.
case "$ORG" in
    *'$('*|*'${'*|*'`'*) die "DEEP_REVIEW_ADO_ORG contains an unexpanded variable: '${ORG}'" ;;
esac

# Checked before the shape check below, and WITHOUT echoing the value, because
# every other rejection message quotes $ORG back to the user and that output
# lands in a reviewer transcript.
case "$ORG" in
    https://*@*) die "DEEP_REVIEW_ADO_ORG must not embed credentials in the URL" ;;
esac

# PIN THE HOST. Keeping the org out of argv decides WHO may set it; it does not
# decide WHAT it may be, and `az` sends the credential to whatever --org names.
# resolve-pr.sh (ado_org_url) can only ever produce these two shapes, so
# anything else is either a mistake or an attempt to redirect the request.
# Matched with a regex, not a glob: a `*` in a case pattern also matches `/`,
# so `https://*.visualstudio.com` would accept `https://evil.test/x.visualstudio.com`.
if ! [[ "$ORG" =~ ^https://dev\.azure\.com/[A-Za-z0-9._~%-]+/?$ ]] \
   && ! [[ "$ORG" =~ ^https://[A-Za-z0-9][A-Za-z0-9-]*\.visualstudio\.com/?$ ]]; then
    die "DEEP_REVIEW_ADO_ORG must be https://dev.azure.com/<org> or https://<org>.visualstudio.com, got '${ORG}'"
fi

command -v az >/dev/null 2>&1 || die "az CLI is required"

# RESOLVE AN INTERPRETER BY RUNNING ONE, not by `command -v`. On Windows,
# %LOCALAPPDATA%\Microsoft\WindowsApps\python3.exe is an App Execution Alias
# that EXISTS on PATH whether or not Python is installed — an existence check
# passes and the interpreter then opens the Microsoft Store instead of running.
# `py -3` is tried because it is the launcher a Windows install always provides.
# Checked separately from az so the two failures do not read alike: without it,
# a missing interpreter surfaces as a parse failure that points at the work item
# rather than at the machine.
PY=""
for candidate in python3 python "py -3"; do
    if $candidate -c "import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)" >/dev/null 2>&1; then
        PY="$candidate"
        break
    fi
done
[[ -n "$PY" ]] \
    || die "Python 3.7+ is required to render the work item; tried python3, python and py -3"

TMPDIR_SELF=$(mktemp -d) || die "could not create a temporary directory"
AZ_ERR="$TMPDIR_SELF/az.err"
PY_SRC="$TMPDIR_SELF/render.py"

# -o json, not tsv: descriptions are HTML and routinely contain newlines and
# tabs, which a tsv parse would shred silently. resolve-pr.sh carries the same
# note about its own --query choices.
# PYTHONIOENCODING because `az` IS a Python program and picks the locale
# encoding for its own stdout; on Linux and macOS under a POSIX locale that
# would otherwise be ascii. It does NOT help on Windows, where `az` ignores it
# and writes the legacy code page anyway — that case is handled by the cp1252
# fallback in the renderer, not here.
if ! WI_JSON=$(PYTHONIOENCODING=utf-8 az boards work-item show --id "$WI_ID" --org "$ORG" -o json 2>"$AZ_ERR"); then
    # Surface az's own diagnostic, indented, the way resolve-pr.sh does. Without
    # it a deleted work item, an expired credential, a missing azure-devops
    # extension and an unreachable network all read as one identical line, and
    # the caller has nothing to act on.
    printf 'workitem-read: could not read work item %s from %s\n' "$WI_ID" "$ORG" >&2
    if [ -s "$AZ_ERR" ]; then
        while IFS= read -r line; do printf '  az: %s\n' "$line" >&2; done < "$AZ_ERR"
    fi
    exit 1
fi

# Heredoc to a file rather than `python -c '...'`: inside a single-quoted -c
# argument a lone apostrophe in a comment or docstring silently terminates the
# string and the rest becomes shell. Feeding the source by path keeps stdin
# free for the payload, which can be far larger than ARG_MAX.
cat > "$PY_SRC" <<'PYSRC'
import html, json, re, sys

sys.stdout.reconfigure(encoding="utf-8", newline="\n")

# Tags that end a line of prose. <ul>/<ol> are handled separately below.
BLOCK = {"p", "div", "h1", "h2", "h3", "h4", "h5", "h6",
         "tr", "table", "section", "blockquote", "pre"}
CELL = {"td", "th"}

# Built from its codepoint: a literal U+00A0 in source is invisible.
NBSP = chr(0xA0)

# Attribute values may legally contain ">", so a naive <[^>]+> stops early and
# leaks the tail of the tag into the output. Skip over quoted runs explicitly.
TAG = re.compile(r"""</?([A-Za-z][A-Za-z0-9]*)((?:[^>"']|"[^"]*"|'[^']*')*)>""")

FENCE_BEGIN = "--- BEGIN UNTRUSTED WORK-ITEM TEXT ---"
FENCE_END = "--- END UNTRUSTED WORK-ITEM TEXT ---"


def invalid_utf8_bytes(buf):
    """Every byte position that makes `buf` invalid UTF-8, not merely the first."""
    bad = set()
    i = 0
    while True:
        try:
            buf[i:].decode("utf-8")
            return bad
        except UnicodeDecodeError as exc:
            bad.update(buf[i + exc.start:i + exc.end])
            i += exc.end


def decode(buf):
    """UTF-8, falling back to cp1252 only for bytes that can only be cp1252.

    `az` on Windows writes its stdout in the legacy code page and ignores
    PYTHONIOENCODING, so an em dash arrives as a bare 0x97 and strict UTF-8
    decoding loses the whole story over one character.

    The fallback is deliberately narrow. cp1252 decodes almost any byte
    sequence, so retrying unconditionally would take a payload that is
    genuinely UTF-8 but has one corrupt byte — a truncated read, a dropped
    chunk — and re-read all of it as cp1252, turning every multi-byte character
    into mojibake. Only bytes in 0x80-0x9F are ambiguous in the way this is
    meant to repair; anything else falls through to a lossy decode that keeps
    the rest of the story intact.
    """
    try:
        return buf.decode("utf-8")
    except UnicodeDecodeError:
        pass
    bad = invalid_utf8_bytes(buf)
    if bad and all(0x80 <= b <= 0x9F for b in bad):
        try:
            return buf.decode("cp1252")
        except UnicodeDecodeError:
            pass
    # Never a raise: a story with one mangled character is still worth grading
    # against.
    return buf.decode("utf-8", errors="replace")


def render(value):
    """HTML to readable plain text.

    ADO stores Description and Acceptance Criteria as HTML. Handing that to the
    model raw wastes context on tags and buries the criteria in <li> soup, and
    the caller is asked to enumerate criteria one per line — so list items
    become lines here rather than leaving the model to infer them.
    """
    if not isinstance(value, str) or not value:
        return ""
    s = re.sub(r"(?i)<br\s*/?>", "\n", value)

    out = []
    stack = []  # one entry per open list: None for <ul>, a running count for <ol>
    pos = 0
    for m in TAG.finditer(s):
        out.append(s[pos:m.start()])
        pos = m.end()
        name = m.group(1).lower()
        closing = m.group(0).startswith("</")

        if name in ("ul", "ol"):
            if closing:
                if stack:
                    stack.pop()
                # Only the CLOSING tag breaks the line. An opening <ul> must not,
                # or a nested list injects a blank line between a parent item and
                # its own child. The break matters here because nothing else
                # separates "</ul>" from the heading that follows it.
                out.append("\n")
            else:
                stack.append(0 if name == "ol" else None)
        elif name == "li" and not closing:
            depth = max(len(stack), 1)
            if stack and stack[-1] is not None:
                stack[-1] += 1
                marker = "%d. " % stack[-1]
            else:
                marker = "- "
            # Indent by nesting depth: a sub-item that renders at the parent's
            # indent reads as a separate acceptance criterion.
            out.append("\n" + "  " * depth + marker)
        elif name in CELL:
            # Cells need a visible separator. Without one, "<td>Env</td><td>Value</td>"
            # renders as the single token "EnvValue".
            if closing:
                out.append(" | ")
        elif name in BLOCK:
            out.append("\n")
        # Everything else — span, a, img, strong, </li> — contributes nothing.
    out.append(s[pos:])
    s = "".join(out)

    # Unescape AFTER stripping, never before: entity-escaped markup in a
    # description (`&lt;div&gt;` in a code sample) is content the author typed,
    # and unescaping first would turn it into a tag for the stripper to delete.
    s = html.unescape(s)
    # ADO's rich-text editor emits &nbsp; heavily, including <p>&nbsp;</p>
    # spacers. U+00A0 survives every whitespace rule below unless normalised.
    s = s.replace(NBSP, " ")
    s = re.sub(r" \| *\n", "\n", s)   # trailing cell separator at end of a row
    s = re.sub(r"[ \t]+\n", "\n", s)
    s = re.sub(r"\n{3,}", "\n\n", s)
    # Trim leading NEWLINES only, not leading whitespace. A plain .strip() also
    # ate the indent of the first "  - " item, so criterion one rendered
    # unindented and the rest indented — the caller is asked to enumerate
    # criteria, and one of them not looking like the others is the whole point
    # of this function.
    return s.rstrip().lstrip("\n")


def fence(body):
    """Wrap field text so it cannot be mistaken for this script's own output.

    A description containing a line "Acceptance criteria:" is otherwise
    byte-identical to a real criteria block, and a work item is writable by
    anyone with board access. Any line that could impersonate a fence marker is
    defanged first, so the fence cannot be closed from inside.
    """
    safe = re.sub(r"(?m)^(\s*)---", r"\1- --", body)
    return "%s\n%s\n%s" % (FENCE_BEGIN, safe, FENCE_END)


def emit(label, value):
    if value is not None and value != "":
        print("%s: %s" % (label, value))


raw = sys.stdin.buffer.read()
if not raw.strip():
    sys.exit("workitem-read: az returned no output for this work item")

try:
    doc = json.loads(decode(raw))
except json.JSONDecodeError as exc:
    sys.exit("workitem-read: az output was not valid JSON (%s)" % exc.msg)
if not isinstance(doc, dict):
    sys.exit("workitem-read: expected a work-item object, got %s" % type(doc).__name__)

f = doc.get("fields")
if not isinstance(f, dict):
    f = {}

emit("id", doc.get("id"))
emit("type", f.get("System.WorkItemType"))
emit("state", f.get("System.State"))
emit("title", f.get("System.Title"))

# Bugs keep their narrative in ReproSteps in both the Agile and Scrum
# templates; System.Description is hidden on the Bug form and is normally
# empty, so a review of a bugfix branch would otherwise get a title and
# nothing else.
SECTIONS = (
    ("Description", ("System.Description", "Microsoft.VSTS.TCM.ReproSteps")),
    ("Acceptance criteria", ("Microsoft.VSTS.Common.AcceptanceCriteria",)),
)

for label, keys in SECTIONS:
    body = ""
    for key in keys:
        body = render(f.get(key))
        if body:
            break
    print()
    if body:
        print("%s:" % label)
        print(fence(body))
    else:
        # Say it rather than omitting the label. Silence cannot be told apart
        # from "this work-item type has no such field", and the caller has to
        # state whether there were criteria to grade against.
        print("%s: (none recorded on this work item)" % label)
PYSRC

# No `|| die` here. The renderer names its own failure precisely — invalid
# JSON, a non-object payload, an empty response — and `set -o pipefail` already
# carries its non-zero status out. A second generic line on top of a specific
# one only buries it.
printf '%s' "$WI_JSON" | $PY "$PY_SRC"
