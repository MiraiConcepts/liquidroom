#!/bin/bash
# uninstall.sh — tear liquidroom down to zero artifacts, in dependency order.
# Documents every step it takes and everything it deliberately leaves.
#
#   sudo bash liquidroom/uninstall.sh
#
# What this does NOT touch, on purpose:
#   - master/liquidroom/ in the Syncthing tree: that is the owner's music,
#     synced to every device. Removing the pipeline does not remove its output.
#   - The repo directory itself (git owns it; revert the commit to finish).
#   - /etc/liquidroom.env is REMOVED here (credentials should not outlive the
#     pipeline) — recreate it from the password manager if reinstalling.
set -uo pipefail

log() { printf '%s\n' "$*"; }
(( EUID == 0 )) || { log "run with sudo: unit removal and /etc need root"; exit 1; }

log "stopping and disabling units..."
systemctl stop liquidroom.triage.path liquidroom.triage.service 2>/dev/null || true
systemctl disable liquidroom.triage.path 2>/dev/null || true

log "removing unit symlinks and policy drop-ins..."
rm -f /etc/systemd/system/liquidroom.triage.path
rm -f /etc/systemd/system/liquidroom.triage.service
rm -rf /etc/systemd/system/liquidroom.triage.service.d
systemctl daemon-reload

log "removing containers and image..."
docker rm -f liquidroom-job 2>/dev/null || true
docker compose -f /zpool/catallenya/docker-compose.yml --profile liquidroom \
    down --rmi local 2>/dev/null || true
docker network rm catallenya_liquidroom 2>/dev/null || true

log "removing credentials..."
rm -f /etc/liquidroom.env

log "removing state (work spool + 1 GB model cache)..."
rm -rf /zpool/catallenya/liquidroom/state

log ""
log "Done. Remaining, by design:"
log "  - master/liquidroom/ (your stems — delete by hand if unwanted)"
log "  - the liquidroom/ repo dir + the integration lines (git revert the commit)"
log "  - the completion stamp at systemd/state/liquidroom.triage (harmless; rm if tidy)"
