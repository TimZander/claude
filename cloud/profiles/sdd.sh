# shellcheck shell=bash disable=SC2034
# Spec-driven development profile: the sdd plugin and nothing else.
#
# Mirrors plugins/sdd/cloud-setup.sh. sdd's conformance-review is the code
# review in this flow, so deep-review is left out. OpenSpec isn't installed
# globally: each repo pins its own version, installed by the repo's SessionStart
# hook. The sdd working agreement replaces the team standards.
PROFILE_DESCRIPTION="Spec-driven development: the sdd plugin, gh, sdd instructions"
PLUGINS="sdd"
APT_PACKAGES="gh"
NPM_PACKAGES=""
VERIFY_COMMANDS="gh"
CLAUDE_MD="cloud/instructions/sdd.md"
