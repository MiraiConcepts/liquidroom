#!/bin/bash
# liquidroom-entrypoint — in-container dispatcher. One verb per container run:
#
#   download <batchid>   Sockseek every request in the batch spec (network run)
#   process  <batchid>   separate + split + mix every downloaded track (no network)
#   fetch-sw             pre-download BS-Roformer-SW into /models (network run)
#
# Per-track outcomes go to /work/<batchid>/manifest.tsv — the host triage reads
# nothing else. The container exits 0 whenever the batch machinery worked, even
# if every track failed: per-track failure is data, not a container error.
#
# NOTE for the deploy-verification step: every sockseek flag and conf key below
# came from research against v3.0.5's docs, not from a local run. Verify with
# `docker compose run --rm liquidroom sockseek-help` before first live use, and
# fix HERE — nothing else in the pipeline knows sockseek exists.
set -uo pipefail

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "FATAL: $*"; exit 1; }

WORK=/work
MODELS=/models
SEP=/opt/venv-sep/bin/audio-separator

manifest() { # $1=idx $2=stage $3=status $4=detail
    # Squash BOTH tab and newline: either would forge a second TSV row the host's
    # awk parser would read. detail is our own static strings today, but aligning
    # with process.py's sanitiser costs nothing and removes a latent trap.
    local d="${4//$'\t'/ }"; d="${d//$'\n'/ }"
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$d" >> "${BATCH_DIR}/manifest.tsv"
}

render_sockseek_conf() {
    # Rendered into the container's tmpfs HOME (read_only rootfs, tmpfs /tmp) —
    # the credentials exist on no disk and no argv, only in this file that dies
    # with the container.
    : "${SLSK_USER:?SLSK_USER not in environment}"
    : "${SLSK_PASS:?SLSK_PASS not in environment}"
    umask 077
    mkdir -p "${HOME}/.config/sockseek"
    cat > "${HOME}/.config/sockseek/sockseek.conf" <<EOF
username = ${SLSK_USER}
password = ${SLSK_PASS}
listen-port = 50300
pref-format = flac
EOF
}

cmd_download() {
    local batch="$1"
    BATCH_DIR="${WORK}/${batch}"
    [[ -f "${BATCH_DIR}/spec.tsv" ]] || die "no spec at ${BATCH_DIR}/spec.tsv"
    render_sockseek_conf

    local idx artist track dl query rc f best
    while IFS=$'\t' read -r idx artist track; do
        [[ -n "$idx" ]] || continue
        dl="${BATCH_DIR}/t${idx}/dl"
        mkdir -p "$dl"
        query="${artist} - ${track}"
        log "[${idx}] sockseek: ${query}"
        rc=0
        # -s is REQUIRED: v3 treats a bare string as an ALBUM query without it.
        # pref-format flac in the conf makes FLAC a preference with automatic
        # fallback to the best high-bitrate lossy result.
        sockseek "$query" -s --output-dir "$dl" || rc=$?
        if (( rc != 0 )); then
            manifest "$idx" dl fail "sockseek exit ${rc}"
            continue
        fi
        # Exactly one audio file is the contract with the processor. Sockseek
        # can leave partials or artwork beside the track; keep the largest
        # audio file, renamed so the separator's default output template
        # reproduces the legacy "<Track> - <Artist>_(Stem)_<model>" names.
        best="$(find "$dl" -type f \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' \
                 -o -iname '*.ogg' -o -iname '*.opus' -o -iname '*.wav' \) \
                 -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2-)"
        if [[ -z "$best" ]]; then
            manifest "$idx" dl fail "no audio file downloaded"
            find "$dl" -mindepth 1 -delete 2>/dev/null
            continue
        fi
        f="${track} - ${artist}.${best##*.}"
        mv -- "$best" "${dl}/.keep.${best##*.}"
        find "$dl" -mindepth 1 ! -name ".keep.*" -delete 2>/dev/null
        mv -- "${dl}/.keep.${best##*.}" "${dl}/${f}"
        manifest "$idx" dl ok "$f"
        log "[${idx}] got ${f}"
    done < "${BATCH_DIR}/spec.tsv"
    exit 0
}

cmd_process() {
    local batch="$1"
    BATCH_DIR="${WORK}/${batch}"
    [[ -f "${BATCH_DIR}/spec.tsv" ]] || die "no spec at ${BATCH_DIR}/spec.tsv"
    exec /opt/venv-sep/bin/python /app/process.py "$BATCH_DIR"
}

cmd_fetch_sw() {
    exec "$SEP" --download_model_only -m BS-Roformer-SW.ckpt --model_file_dir "$MODELS"
}

case "${1:-}" in
    download)      [[ -n "${2:-}" ]] || die "usage: download <batchid>"; cmd_download "$2" ;;
    process)       [[ -n "${2:-}" ]] || die "usage: process <batchid>";  cmd_process "$2" ;;
    fetch-sw)      cmd_fetch_sw ;;
    sockseek-help) exec sockseek --help ;;
    separator-help) exec "$SEP" --help ;;
    --help|help|"") echo "verbs: download <batchid> | process <batchid> | fetch-sw | sockseek-help | separator-help"; exit 0 ;;
    *)             die "unknown verb: $1" ;;
esac
