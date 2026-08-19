#!/bin/bash
# models.sh — fetch the separation models into state/models/. EVERY file is
# pinned by sha256, and the pins live in liquidroom.lib.sh (MODEL_PINS) because
# the triage re-checks them before every separation run; this script is only the
# fetcher.
#
# The listra92 lead/rhythm checkpoint is a COMMUNITY artifact re-hosted in a
# mirror repo (noblebarkrr/mvsepless_resources). A torch checkpoint is a pickle;
# the pin plus torch>=2.6's weights_only default plus the network_mode:none
# inference container are the three mitigations, together.
#
# BS-Roformer-SW is fetched by audio-separator's own registry machinery (which
# needs network, so it runs via the `liquidroom-soulseek` service, not
# `-roformer`). That downloader does its own integrity checking against its own
# registry and hands us no way to state an expected digest — so the pin is
# enforced HERE, after the files land and before anything loads them.
#
#   bash liquidroom/scripts/models.sh
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/zpool/catallenya/liquidroom/scripts/liquidroom.lib.sh
source "${SELF_DIR}/liquidroom.lib.sh"

HF_BASE="https://huggingface.co/noblebarkrr/mvsepless_resources/resolve/main/mel_band_roformer"
CKPT="mbr_lead_rhythm_guitar_listra92.ckpt"
YAML="mbr_lead_rhythm_guitar_listra92_config.yaml"

mkdir -p "$MODELS_DIR"

fetch() { # $1=filename $2=sha256
    local f="${MODELS_DIR}/$1" tmp
    if [[ -f "$f" ]] && sha256sum -c --status <<<"$2  $f"; then
        log "$1 already present and verified"
        return 0
    fi
    tmp="$(mktemp "${MODELS_DIR}/.dl.XXXXXX")"
    log "fetching $1 ..."
    curl -fSL --retry 3 -o "$tmp" "${HF_BASE}/$1" || { rm -f "$tmp"; die "download failed: $1"; }
    sha256sum -c --status <<<"$2  $tmp" || { rm -f "$tmp"; die "sha256 MISMATCH for $1 — refusing to keep it"; }
    mv -- "$tmp" "$f"
    log "$1 verified and installed"
}

fetch "$CKPT" "$(model_sha "$CKPT")"
fetch "$YAML" "$(model_sha "$YAML")"

# BS-Roformer-SW (667 MB) via audio-separator's own downloader, into the same
# mounted models dir. Needs network -> the `liquidroom-soulseek` service. Harmless if
# already present; audio-separator skips existing files.
# Own container name, NOT liquidroom-job: this script runs OUTSIDE the triage's
# flock, and sharing the name would let a manual fetch and a live triage each
# force-remove the other's container.
log "fetching BS-Roformer-SW via audio-separator (skips if present) ..."
docker compose -f "$COMPOSE_FILE" run --rm --name liquidroom-fetch \
    liquidroom-soulseek fetch-sw \
    || die "BS-Roformer-SW fetch failed — is the image built? (docker compose build liquidroom-soulseek)"

# Everything, cached and freshly downloaded alike, against the same pins the
# triage will use. audio-separator "skips if present", so a corrupted or swapped
# cached copy is exactly the case a fetcher never notices on its own.
verify_models || die "model verification FAILED — nothing above is safe to load"

log "models ready in ${MODELS_DIR}"
