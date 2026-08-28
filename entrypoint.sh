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
# `docker compose run --rm liquidroom-soulseek sockseek-help` before first live use, and
# fix HERE — nothing else in the pipeline knows sockseek exists.
set -uo pipefail

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "FATAL: $*"; exit 1; }

# The two bind mounts. /work is overridable ONLY so the test suite can drive
# cmd_download against a scratch tree with a fake `sockseek` on PATH — the same
# seam LR_ROOT/STATE_DIR are on the host side, and never set in production.
# /models deliberately is NOT: nothing tests the fetch verb, and a stray env var
# is not something a 700 MB download should be able to follow.
WORK="${LR_WORK:-/work}"
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
    # Verified against sockseek 3.0.5's own `--help config` / `--help`: this path
    # and `key = value` syntax are what it reads, and every key below is real.
    cat > "${HOME}/.config/sockseek/sockseek.conf" <<EOF
username = ${SLSK_USER}
password = ${SLSK_PASS}
listen-port = 50300
pref-format = flac
pref-strict-title = true
pref-strict-artist = true
pref-min-samplerate = 44100
pref-max-samplerate = 44100
pref-min-bitdepth = 16
EOF
    # WHAT WE ARE ACTUALLY ASKING FOR IS A CD RIP, and every line above is a proxy
    # for that rather than a preference about audio (added 2026-08-28, after a
    # request came back sounding flat).
    #
    # 44.1kHz is the PROVENANCE lever, which is the non-obvious one. A file at
    # 44100 almost certainly came off a CD; one at 48000 almost certainly came off
    # video or a stream. So targeting 44100 selects for a source, not a sample
    # rate — and `flac` has always been the same kind of proxy. The measured case:
    # a 48kHz "FLAC" of a 2006 album arrived with 14dB less energy above 19.5kHz
    # than the other tracks in this library and a stereo image 7dB narrower. It was
    # a transcode in a lossless container, and sockseek's DEFAULT
    # pref-max-samplerate is 48000, so nothing here objected.
    #
    # Deprioritising 96kHz/24-bit hi-res is a knowing cost. Those are legitimate
    # sources, but they barely exist for the catalogue this pipeline is asked for,
    # and the separator resamples everything to 44100 regardless — so the rare loss
    # is a file that would have been downsampled anyway.
    #
    # pref-min-bitdepth has a FLOOR and no ceiling on purpose: 16 is CD, and 24-bit
    # is a better source rather than a worse one. Only the sample rate is pinned to
    # exactly CD, because only the sample rate distinguishes a rip from a stream.
    #
    # ALL OF THESE ARE PREFERENCES (pref-*), NEVER REQUIREMENTS. They rank
    # candidates; they do not exclude. A track that exists only as a 48kHz file
    # still downloads, because a flat copy beats no copy. Switching any of them to
    # --cond/--format would turn a ranking into a refusal, which is a different
    # decision and not this one.
    #
    # THE LIMIT OF ALL OF IT: Soulseek metadata is SELF-REPORTED, and a transcoded
    # FLAC reports itself honestly as FLAC at 48kHz. Every fact on the label is
    # true. Nothing here can catch a lie that is not in the label — that needs the
    # file decoded and its spectrum measured, which is a separate change.
    #
    # pref-strict-title/artist are the other half, and aim at a different failure:
    # they prefer candidates whose filename actually carries the artist and title,
    # which is the only cheap defence against the pipeline separating and
    # publishing a completely different song under the requested name.

    # Search-rate ceiling. Sockseek's own docs warn that a high value earns a
    # 30-minute server ban ("Higher values may cause 30-minute bans"), and its
    # default 34 is tuned for bulk playlist runs. This pipeline searches once per
    # human request, so the generous default buys nothing and only carries the
    # ban risk; 8 is far above anything a batch of 4 can reach.
    printf 'searches-per-time = 8\n' >> "${HOME}/.config/sockseek/sockseek.conf"
}

cmd_download() {
    local batch="$1"
    BATCH_DIR="${WORK}/${batch}"
    [[ -f "${BATCH_DIR}/spec.tsv" ]] || die "no spec at ${BATCH_DIR}/spec.tsv"
    render_sockseek_conf

    local idx artist track dl query rc f best ext
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
        #
        # </dev/null because this loop's stdin IS spec.tsv. Sockseek does not
        # read stdin today; the day it does — a prompt, a y/n, a newer version
        # draining what it finds — it silently eats the rest of the batch and
        # every remaining track vanishes with no error anywhere.
        sockseek "$query" -s --output-dir "$dl" </dev/null || rc=$?
        if (( rc != 0 )); then
            manifest "$idx" dl fail "sockseek exit ${rc}"
            continue
        fi
        # Exactly one audio file is the contract with the processor. Sockseek
        # can leave partials or artwork beside the track; keep the largest
        # audio file, renamed so the separator's default output template
        # reproduces the legacy "<Track> - <Artist>_(Stem)_<model>" names.
        #
        # NUL-delimited end to end, and read into the variable rather than
        # captured with $( ): a peer controls this filename, it may contain (or
        # END in) a newline, and command substitution strips trailing newlines
        # and drops NUL bytes. Either would hand back a path that does not
        # exist, after which the mv fails and the cleanup below deletes the real
        # download. `read` takes the first record — sort -zrn already put the
        # largest there.
        best=""
        IFS= read -r -d '' best < <(
            find "$dl" -type f \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' \
                 -o -iname '*.ogg' -o -iname '*.opus' -o -iname '*.wav' \) \
                 -printf '%s\t%p\0' 2>/dev/null | sort -zrn | cut -z -f2-) || best=""
        if [[ -z "$best" ]]; then
            manifest "$idx" dl fail "no audio file downloaded"
            find "$dl" -mindepth 1 -delete 2>/dev/null
            continue
        fi
        ext="${best##*.}"
        f="${track} - ${artist}.${ext}"
        # BOTH renames are checked, and -T so neither can silently become a move
        # INTO a directory of that name. The find between them deletes
        # everything not called .keep.* — so a first mv that failed while the
        # code carried on would have the cleanup erase the very file it was
        # supposed to be protecting, and the slot would then report a rename
        # failure with nothing left to retry. A failed rename is one slot's
        # failure; it is never data loss.
        if ! mv -T -- "$best" "${dl}/.keep.${ext}" 2>/dev/null; then
            manifest "$idx" dl fail "could not stage the downloaded file"
            continue
        fi
        find "$dl" -mindepth 1 ! -name ".keep.*" -delete 2>/dev/null
        if ! mv -T -- "${dl}/.keep.${ext}" "${dl}/${f}" 2>/dev/null; then
            manifest "$idx" dl fail "could not rename the downloaded file"
            continue
        fi
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
