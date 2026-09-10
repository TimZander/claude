#!/usr/bin/env bash
set -euo pipefail

# workitem-read.sh — Print an Azure DevOps work item's story fields as plain
# text, for /deep-review Step 1c to grade a diff against.
#
# Usage:
#   DEEP_REVIEW_ADO_ORG=https://dev.azure.com/<org> bash workitem-read.sh <id>
#
# Output on stdout: a small labelled block (id, type, state, title, then
# Description and Acceptance criteria). Errors go to stderr; a failure here is
# never fatal to a review — the caller reports "found but not fetchable" and
# carries on.
#
# WHY THIS EXISTS AT ALL, when `az boards work-item show` is one command.
#
# Because in a constrained runner the CALLER cannot run it. The hosted reviewer
# (ClaudeCodeReview) drives the model with a narrow `--allowedTools` list that
# deliberately contains NO `az` rule: `az`, like every argparse CLI, honours the
# LAST occurrence of a repeated option, so `--org <pinned> --org https://evil/x`
# satisfies any prefix rule and ships the token off-org. That rule was removed
# after exactly that analysis.
#
# So Step 1c's `az boards work-item show` — written for a developer's
# unrestricted shell — silently cannot run there, and an ADO reviewer resolves a
# work item id and then reports it as unfetchable. This script is the same
# command behind a surface the runner CAN allow: one named script, one
# argument, and the organization taken from the ENVIRONMENT rather than from
# anything the model writes. `tfvc-read.py` earns its allow-rule the same way,
# and its header records the same reasoning.
#
# THE ENVIRONMENT IS THE CONTROL, and it holds in both directions:
#   * Constrained: the runner exports DEEP_REVIEW_ADO_ORG and allows
#     `Bash(bash <path>/workitem-read.sh *)`. A model writing
#     `DEEP_REVIEW_ADO_ORG=https://evil bash …` does not match that rule — the
#     command starts with the assignment, not with `bash` — so it is denied.
#   * Unconstrained: a developer's session sets it inline from the ORG that
#     resolve-pr.sh already reported. Same script, same one code path.
#
# NOT DERIVED FROM THE GIT REMOTE, though that would need no input at all:
# resolve-pr.sh owns remote parsing (ado_org_name / ado_org_url) and a second
# copy here is precisely the drift this repo keeps removing — there is already a
# branch extracting that parsing into a shared library. When it lands, deriving
# here becomes a one-line call and this variable can become a fallback rather
# than a requirement.

die() { printf 'workitem-read: %s\n' "$*" >&2; exit 1; }

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
# An unexpanded pipeline macro arrives as the literal '$(Something)': non-empty,
# so an emptiness check passes it, and `az` would then fail with something far
# less obvious than this. run-review.sh and central-pr-review.yml both fail
# closed on this same class.
case "$ORG" in
    *'$('*) die "DEEP_REVIEW_ADO_ORG contains an unexpanded variable: '${ORG}'" ;;
    https://*) ;;
    *) die "DEEP_REVIEW_ADO_ORG must be an absolute https:// URL, got '${ORG}'" ;;
esac

command -v az >/dev/null 2>&1 || die "az CLI is required"
# Checked separately from az so the two failures do not read alike. Without
# this, a missing interpreter surfaces as the generic parse failure below and
# points at the work item rather than at the machine.
command -v python3 >/dev/null 2>&1 || die "python3 is required to render the work item"

# -o json, not tsv: descriptions are HTML and routinely contain newlines and
# tabs, which a tsv parse would shred silently. resolve-pr.sh carries the same
# note about its own --query choices.
# PYTHONIOENCODING, because `az` IS a Python program and picks the locale
# encoding for its own stdout. On Windows that is a legacy code page: an em dash
# in a description arrived as byte 0x97 (cp1252), which is not valid UTF-8 at
# all, so the story this script exists to deliver failed to parse entirely.
WI_JSON=$(PYTHONIOENCODING=utf-8 az boards work-item show --id "$WI_ID" --org "$ORG" -o json 2>/dev/null) \
    || die "could not read work item ${WI_ID} from ${ORG}"

printf '%s' "$WI_JSON" | python3 -c '
import html, json, re, sys

# READ AND WRITE UTF-8 EXPLICITLY. Python picks the locale encoding for stdio,
# which on Windows is a legacy code page — an em dash in a work-item
# description came back as a replacement character, and the acceptance criteria
# are exactly the text the reviewer grades against.
# DECODE UTF-8, THEN FALL BACK TO CP1252. `az` on Windows writes its own stdout
# in the legacy code page and ignores PYTHONIOENCODING, so an em dash arrives as
# a bare 0x97 — not valid UTF-8, and strict decoding lost the whole story over
# one character. cp1252 is the only encoding that byte can plausibly be, and
# trying it second means nothing changes on Linux or macOS, where the first
# decode always succeeds.
#
# errors="replace" on the last attempt, never a raise: a story with one mangled
# character is still worth grading against.
raw = sys.stdin.buffer.read()
for enc, errs in (("utf-8", "strict"), ("cp1252", "strict"), ("utf-8", "replace")):
    try:
        doc = json.loads(raw.decode(enc, errors=errs))
        break
    except (UnicodeDecodeError, json.JSONDecodeError):
        continue
else:
    sys.exit("workitem-read: work item payload could not be decoded")
sys.stdout.reconfigure(encoding="utf-8", newline="\n")
f = doc.get("fields") or {}

def text(value):
    """HTML to readable plain text.

    ADO stores Description and Acceptance Criteria as HTML. Handing that to the
    model raw wastes context on tags and buries the criteria in <li> soup, and
    the caller is asked to enumerate criteria one per line -- so list items
    become lines here rather than leaving the model to infer them.
    """
    if not value:
        return ""
    s = re.sub(r"(?i)<br\s*/?>", "\n", value)
    # Every block boundary, opening AND closing. Closing tags alone lost the
    # break between a list and the heading after it -- "</ul><h3>Why this is
    # tracked</h3>" ran the heading onto the previous line, because nothing
    # matched </ul> or <h3.
    s = re.sub(r"(?i)</?(p|div|h[1-6]|tr|ul|ol|table|section|blockquote)[^>]*>", "\n", s)
    s = re.sub(r"(?i)</li>", "", s)
    s = re.sub(r"(?i)<li[^>]*>", "\n  - ", s)
    s = re.sub(r"<[^>]+>", "", s)
    s = html.unescape(s)
    # Collapse the blank-line drifts the tag stripping leaves behind.
    s = re.sub(r"[ \t]+\n", "\n", s)
    s = re.sub(r"\n{3,}", "\n\n", s)
    # Trim leading NEWLINES only, not leading whitespace. A plain .strip() also
    # ate the indent of the first "  - " item, so criterion one rendered
    # unindented and the rest indented -- the caller is asked to enumerate
    # criteria, and one of them not looking like the others is the whole point
    # of this function.
    return s.rstrip().lstrip("\n")

def emit(label, value):
    if value:
        print(f"{label}: {value}")

emit("id", doc.get("id"))
emit("type", f.get("System.WorkItemType"))
emit("state", f.get("System.State"))
emit("title", f.get("System.Title"))

for label, key in (("Description", "System.Description"),
                   ("Acceptance criteria", "Microsoft.VSTS.Common.AcceptanceCriteria")):
    body = text(f.get(key))
    if body:
        print()
        print(f"{label}:")
        print(body)
' || die "could not parse work item ${WI_ID}"
