#!/usr/bin/env bash
# Smoke test for origin-info.sh: usage error, each remote form start-work recognizes,
# unknown hosts, a missing origin, and that credentials in the URL are never printed.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUT="$SCRIPT_DIR/origin-info.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# 1. OriginInfo_TooManyArguments_ExitsWithUsage
# Arrange
exit_usage=2
# Act
rc=0
bash "$SUT" one two >/dev/null 2>&1 || rc=$?
# Assert
[ "$rc" -eq "$exit_usage" ] || fail "expected exit $exit_usage for two arguments, got $rc"
pass "two arguments is a usage error"

# 2. OriginInfo_KnownRemoteForms_ClassifiedWithOrgAndProject
#    Each case is "<url>|<expected output, lines joined by ;>".
# Arrange
nl='
'
# Act / Assert
while IFS='|' read -r url expected; do
    [ -n "$url" ] || continue
    out="$(bash "$SUT" "$url")"
    [ "$out" = "${expected//;/$nl}" ] || fail "for $url expected '$expected', got: ${out//$nl/;}"
done <<'CASES'
https://github.com/TimZander/claude.git|SOURCE=github
git@github.com:TimZander/claude.git|SOURCE=github
ssh://git@ssh.github.com:443/TimZander/claude.git|SOURCE=github
HTTPS://GitHub.COM/TimZander/claude|SOURCE=github
https://dev.azure.com/bgvone/BGV%20Development/_git/Web|SOURCE=ado;ORG=bgvone;PROJECT=BGV Development
https://bgvone@dev.azure.com/bgvone/Proj/_git/Repo|SOURCE=ado;ORG=bgvone;PROJECT=Proj
https://user:p%40ss@word@dev.azure.com/bgvone/Proj/_git/Repo|SOURCE=ado;ORG=bgvone;PROJECT=Proj
https://dev.azure.com/bgvone/_git/SameName|SOURCE=ado;ORG=bgvone;PROJECT=SameName
https://Dev.Azure.com/bgvone/Proj/_git/Repo/|SOURCE=ado;ORG=bgvone;PROJECT=Proj
git@ssh.dev.azure.com:v3/bgvone/BGV%20Development/Web|SOURCE=ado;ORG=bgvone;PROJECT=BGV Development
ssh://git@ssh.dev.azure.com/v3/bgvone/Proj/Repo|SOURCE=ado;ORG=bgvone;PROJECT=Proj
bgvone@vs-ssh.visualstudio.com:v3/bgvone/Proj/Repo|SOURCE=ado;ORG=bgvone;PROJECT=Proj
https://bgvone.visualstudio.com/Proj/_git/Repo|SOURCE=ado;ORG=bgvone;PROJECT=Proj
https://bgvone.visualstudio.com/DefaultCollection/Proj/_git/Repo|SOURCE=ado;ORG=bgvone;PROJECT=Proj
https://bgvone.visualstudio.com/DefaultCollection/_git/Repo|SOURCE=ado;ORG=bgvone;PROJECT=Repo
https://user@bgvone.visualstudio.com/_git/Repo|SOURCE=ado;ORG=bgvone;PROJECT=Repo
https://dev.azure.com/bgvone|SOURCE=ado;ORG=bgvone;PROJECT=
https://github.example.com/org/repo.git|SOURCE=other
https://bitbucket.org/org/repo.git|SOURCE=other
https://github.com.evil.example/org/repo|SOURCE=other
https://dev.azure.com.evil.example/org/proj/_git/r|SOURCE=other
https://evil.example/dev.azure.com/org/proj/_git/r|SOURCE=other
/srv/git/repo.git|SOURCE=other
CASES
pass "known remote forms are classified with organization and project"

# 3. OriginInfo_PercentEncodedControlCharacter_ProjectLeftEmpty
# Arrange
url="https://dev.azure.com/bgvone/Bad%0AName/_git/Repo"
expected="SOURCE=ado${nl}ORG=bgvone${nl}PROJECT="
# Act
out="$(bash "$SUT" "$url")"
# Assert
[ "$out" = "$expected" ] || fail "expected an empty project for an encoded newline, got: $out"
pass "a project that decodes to a control character is left empty"

# 4. OriginInfo_CredentialsInUrl_NeverPrinted
# Arrange
secret="s3cr3t-token"
url="https://someone:$secret@dev.azure.com/bgvone/Proj/_git/Repo"
# Act
out="$(bash "$SUT" "$url" 2>&1)"
# Assert
grep -qF -- "$secret" <<<"$out" && fail "the token in the URL was printed"
grep -qF -- "someone" <<<"$out" && fail "the user name in the URL was printed"
pass "credentials in the URL are never printed"

# 5. OriginInfo_NoOriginRemote_ReportsNone
# Arrange
repo="$TMP_ROOT/no-origin"
git init -q "$repo"
# Act
out="$( cd "$repo" && bash "$SUT" )"
# Assert
[ "$out" = "SOURCE=none" ] || fail "expected SOURCE=none without an origin, got: $out"
pass "a repository with no origin reports SOURCE=none"

# 6. OriginInfo_NoArgument_ReadsOriginRemote
# Arrange
repo="$TMP_ROOT/with-origin"
git init -q "$repo"
( cd "$repo" && git remote add origin "https://dev.azure.com/bgvone/Proj/_git/Repo" )
expected="SOURCE=ado${nl}ORG=bgvone${nl}PROJECT=Proj"
# Act
out="$( cd "$repo" && bash "$SUT" )"
# Assert
[ "$out" = "$expected" ] || fail "expected the origin remote to be read, got: $out"
pass "with no argument the origin remote is read"

echo "all smoke tests passed"
