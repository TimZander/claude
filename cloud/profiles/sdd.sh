# shellcheck shell=bash disable=SC2034
# Spec-driven development profile: OpenSpec on top of the core workflow.
#
# TODO: replace deep-review with the SDD review plugins, and add the SDD
# workflow plugins, once they exist in this marketplace.
PROFILE_DESCRIPTION="Spec-driven development: OpenSpec, team standards, workflow plugins, gh"
PLUGINS="deep-review craft-pr craft-stage-commit-push start-work self-review"
APT_PACKAGES="gh"
NPM_PACKAGES="@fission-ai/openspec@latest"
VERIFY_COMMANDS="gh openspec"
