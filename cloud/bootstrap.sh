#!/bin/bash
# Cloud environment setup for Claude Code — paste this into the environment's
# Setup script field, then set PROFILE below. See README "Claude Code Cloud
# Sessions" for the available profiles.
#
# This stub only clones TimZander/claude and runs cloud/setup.sh with a profile,
# so profile changes merged to the repo need no re-paste. They do need a cache
# rebuild: the setup script runs only when no cached environment exists, and
# editing this stub (e.g. bumping REVISION) forces one.
#
# Runs as root on Ubuntu 24.04 BEFORE Claude Code launches. Must exit zero — a
# non-zero exit fails the session. Keep total runtime under ~5 minutes.

PROFILE="default"   # default | sdd
REF="main"          # branch or tag of TimZander/claude to set up from
REVISION=1          # bump to force a cache rebuild

LOG=/root/setup-script.log
exec > >(tee -a "$LOG") 2>&1
echo "=== setup started $(date -u) (profile=${PROFILE} ref=${REF} rev=${REVISION}) ==="

SRC=/tmp/tzander-claude
rm -rf "$SRC"
if git clone --depth 1 --branch "$REF" https://github.com/TimZander/claude "$SRC"; then
    bash "$SRC/cloud/setup.sh" "$PROFILE" "$SRC" || echo "WARNING: setup.sh exited $?"
else
    echo "WARNING: could not clone TimZander/claude@${REF} — nothing installed"
fi
rm -rf "$SRC"

echo "=== setup finished $(date -u) ==="
exit 0
