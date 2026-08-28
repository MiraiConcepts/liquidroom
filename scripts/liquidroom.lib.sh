#!/bin/bash
# shellcheck disable=SC2034  # config vars are consumed by the scripts that source this
# Shared helpers for the liquidroom pipeline (request marker -> Soulseek download
# -> stems). Sourced by liquidroom.triage.sh — not executable on its own.
#
# No AI transport here: unlike pigeonhole/capture, this pipeline never talks to
# api.anthropic.com, and as of the ntfy.lib.sh extraction it no longer sources the
# AI layer at all. It takes the notification transport and its two sanitisers from
# ntfy/ntfy.lib.sh — a title here carries a filename synced in from another device,
# and hdr_safe/md_escape must not exist as a second drifting copy.

set -uo pipefail

# shellcheck source=/zpool/catallenya/ntfy/ntfy.lib.sh
source "/zpool/catallenya/ntfy/ntfy.lib.sh"

# --- notification vocabulary -------------------------------------------------
# Declared here, never centrally — the same shape as a unit's [X-Catallenya] Class=
# sticker. systemd/contract.sh reads these; every entry must be a past participle.
# See ntfy/MESSAGES.md.
#
# liquidroom NEVER calls the API — it does not source ai/scripts/ai.lib.sh at all —
# so none of the model-class verbs may appear here. Its failures are its own, and
# they are split by STAGE because the remedies differ: a Dropped download is
# re-requested, a Halted separation is re-run, an Unpublished track means the disk.
#
# `Refused` `Skipped` `Stranded` `Stuck` are shared with the intake pipelines because
# the situations match, not because a rule forces it.
#
# SIX NOUNS, because the verb does not always act on the track: a download that never
# arrived is a Download, a separation that died is a Separation, a separator output
# that failed a safety check is a Result.
# shellcheck disable=SC2034  # consumed by systemd/contract.sh
NTFY_VERBS=(Finished Downloaded Dropped Halted Emptied Raced Unpublished
            Refused Skipped Stranded Stuck)
# shellcheck disable=SC2034  # consumed by systemd/contract.sh
NTFY_NOUNS=(Track Download Separation Publish Result File)
# The Syncthing quiet gate, shared with pigeonhole — st_apikey / st_api_base /
# st_folder_idle / syncthing_quiet, the folder id (master/liquidroom and
# master/documents are the same Syncthing folder, so one id answers for both) and
# the SKIP_SYNCTHING_GATE test seam. This file carried the second byte-identical
# copy; the only thing that differed was the watched directory, now an argument.
# shellcheck source=/zpool/catallenya/syncthing/syncthing.lib.sh
source "/zpool/catallenya/syncthing/syncthing.lib.sh"

# Overridable ONLY so the test suite can run against a scratch tree — same seam
# as DOCS/STATE_DIR in pigeonhole.lib.sh. Never set in production; the defaults
# are the only values systemd ever runs with.
LR_ROOT="${LR_ROOT:-/zpool/catallenya/syncthing/data/master/liquidroom}"
STATE_DIR="${STATE_DIR:-/zpool/catallenya/liquidroom/state}"
LOCK_FILE="${STATE_DIR}/.intake.lock"
WORK_DIR="${STATE_DIR}/work"
MODELS_DIR="${STATE_DIR}/models"
# Inside the synced tree deliberately (documents bin/ precedent): a parked stray
# is visible and recoverable on every device. Never auto-emptied.
REJECTED_DIR="${LR_ROOT}/rejected"

# The compose file that defines the two liquidroom services. A seam so the tests
# can point the triage at a scratch compose (the fake `docker` ignores it anyway).
COMPOSE_FILE="${COMPOSE_FILE:-/zpool/catallenya/docker-compose.yml}"

# Batch cap. Batching makes marginal tracks cheap (one model load per batch, not
# per track) — but separation is ~9.4x realtime on this CPU, so each extra track
# is a real half-hour of wall clock and the stage timeouts scale by N. 3 keeps
# the worst case inside TimeoutStartSec; the rest wait for the next fire, which
# costs only one extra model load.
MAX_PER_RUN="${MAX_PER_RUN:-3}"

# Per-track stage budgets, multiplied by the batch size for the real timeout.
# Download: Sockseek walks up to 10 candidates on dead peers; 15 min covers a slow
# FLAC from a modem-grade peer.
#
# Process: MEASURED on this box 2026-08-14, not estimated. BS-Roformer-SW at
# overlap 2 (already the fastest setting; the range is 2-50) took 31 min for a
# 3:20 track — about 9.4x realtime, and the published "5-15 min" figures are
# GPU-era optimism. Budget from that measurement: 9.4x realtime means a 6-minute
# song is ~56 min, plus the lead/rhythm split on the guitar stem and the ffmpeg
# mixes. 90 min per track covers a long song with headroom; a 10-minute epic
# would still time out, which is the correct failure (it notifies and drains).
DL_TIMEOUT_S="${DL_TIMEOUT_S:-900}"
PROC_TIMEOUT_S="${PROC_TIMEOUT_S:-5400}"

# A request marker is an EMPTY file whose NAME is the request. Anything carrying
# real content is not a marker — someone dropped an actual file here by mistake,
# and deleting it would destroy data, so it goes to rejected/ instead.
#
# The test is CONTENT, not size (changed 2026-08-19). A size threshold decided
# nothing useful in either direction: a 40-byte shopping list named
# "Milk - Bread.txt" was a "marker", read as a request, and DELETED once its
# outcome was decided; while a 5 KB file was parked purely for being large.
# Emptiness is the property that actually distinguishes a command from a
# document, so that is what is measured — after stripping a UTF-8 BOM and every
# whitespace byte, because "touch" on a phone-side editor routinely leaves a
# newline and Windows editors routinely leave a BOM, and neither is content a
# human typed. ANYTHING else remaining means the file is data: park it.
#

# Stale work dirs survive this long for failure autopsies, then are purged at the
# start of the next run. Matches capture's PRUNE_IMAGE_AFTER_DAYS spirit.
WORK_KEEP_DAYS="${WORK_KEEP_DAYS:-7}"

NTFY_TOPIC="liquidroom"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# --- request parsing --------------------------------------------------------

# portable_segment <trimmed-segment> — beets' default `replace` table, minus the
# rules valid_segment_lr already REFUSES outright.
#
# Windows rejects < > : " ? * | outright and silently eats a trailing dot, and
# Syncthing does not translate: a receiving Windows peer parks the item as a
# failed item and RETRIES IT FOREVER, so one such title leaves that device
# permanently out of sync. "The Strokes - What Ever Happened?" did exactly that
# — legion sat at 99.33% on `master` needing precisely that folder and its 12
# files (77,499,992 bytes, a byte-for-byte match) from 2026-08-20 until this
# landed. Nothing on THIS side reported it: the error lives on the Windows box,
# so the host looks healthy while a peer is stuck.
#
# The substitution therefore happens at WRITE time and on every platform, which
# is where beets (this table, all platforms, by default), Picard and yt-dlp all
# converged — a name is portable or it is not, and the receiving end never gets
# a say. This REVERSES the 2026-08-15 "the requested title is authoritative"
# call, which held only while every device ran a real filesystem.
#
# The other four beets rules are already here as REFUSALS, which is stronger:
# `[\\/]`, `^\.`, `^-` and the control-byte class are rejected outright by
# valid_segment_lr for reasons (path traversal, argv injection) that outlive
# portability. Reserved DEVICE names — CON, NUL, COM1… — are a known gap;
# beets does not cover them either.
portable_segment() { # $1 = one already-trimmed path component
    local LC_ALL=C s="$1"
    s="${s//[<>:\"?*|]/_}"
    [[ "$s" == *. ]] && s="${s%.}_"
    printf '%s' "$s"
}



# Path safety. Deliberately NOT documents' valid_segment(): that allowlist bounds
# model-emitted free text to lowercase ASCII, and this pipeline's inputs are
# owner-authored song titles — the existing stems library is full of
# Japanese (二人のいた風景, 昼間から夜), which an ASCII enum would refuse
# wholesale. So this is byte-wise (LC_ALL=C) and rejects only what can break a
# path or a header:
#   - empty, "." or ".." as the WHOLE segment (a lone dot component retargets the
#     move; ".." inside a title — "I Don't Know Why..." — is a real title and
#     harmless once "/" is impossible, which is why this differs from documents)
#   - a leading dot (hidden files; also ntfy_id-style stripping precedent)
#   - a leading "-" (an "-rf - x.txt" marker parses to artist "-rf", which would
#     reach `sockseek "$query"` as a dash-leading token — the query always holds
#     the literal " - " so it is never a clean single flag, but a dash-leading
#     positional makes an argument parser's behaviour input-dependent; forbid it
#     rather than depend on every downstream tool's `--` support. Real titles
#     starting with a literal hyphen are vanishingly rare.)
#   - "/" or "\" (the only characters that make one segment two)
#   - any control byte, CR/LF and TAB included (header injection via the notify
#     title; TAB would also desync the spec.tsv columns)
#   - longer than 100 bytes. The cap is PER SEGMENT but the segments are
#     recombined into one filename ("<track> - <artist>_(Rhythm Guitar)_...mp3"),
#     so two maxed halves plus the ~31-byte suffix must stay under NAME_MAX 255:
#     100 + 100 + 31 = 231. A larger per-segment cap silently overflows into
#     ENAMETOOLONG in the container (drains as a failure, but needlessly).
valid_segment_lr() { # $1 = one proposed path component
    local LC_ALL=C s="$1"
    [[ -n "$s" ]] || return 1
    (( ${#s} <= 100 )) || return 1
    [[ "$s" != "." && "$s" != ".." ]] || return 1
    [[ "$s" != .* && "$s" != -* ]] || return 1
    [[ "$s" != *"/"* && "$s" != *"\\"* ]] || return 1
    [[ "$s" == "$(tr -d '\000-\037\177' <<<"$s")" ]] || return 1
    return 0
}

# Belt to valid_segment_lr: resolve the assembled path and require it to land
# under LR_ROOT. A failure here means the charset check was bypassed. -m so a
# not-yet-existing destination still resolves. (under_docs() adaptation.)
under_root() { # $1 = candidate absolute path
    local real
    real="$(realpath -m -- "$1" 2>/dev/null)" || return 1
    [[ "$real" == "${LR_ROOT}/"* ]]
}

# --- folder requests --------------------------------------------------------
# A request is an EMPTY DIRECTORY at <Artist>/<Track>/, i.e. exactly where its
# result will land. The state machine is the filesystem and nothing else:
#
#   absent            never asked for
#   empty             please make this
#   holds FAILED-*    tried, did not work, the note says why
#   holds 12 files    done
#
# Two mechanics carry the whole design, both verified on this box before it was
# written: a directory holding only a marker is NOT -empty, and `mv -T` REFUSES to
# publish over a non-empty directory, so a failure note can never be clobbered by
# a later run.

MARKER_PREFIX="FAILED - "

# marker_reason <verb> — the sentence that goes in the marker filename and body,
# mapped from the notification verb so the phone and the folder cannot disagree
# about what happened. Filename-safe by construction: no slashes, no reserved
# characters. An unmapped verb is a programming error rather than a user one, so
# it gets a generic reason instead of an empty filename.
marker_reason() {
    case "$1" in
        Dropped)     printf 'no audio file was found' ;;
        Halted)      printf 'separation did not finish' ;;
        Refused)     printf 'the destination was unsafe' ;;
        Emptied)     printf 'the separator produced nothing' ;;
        Unpublished) printf 'the result could not be moved into place' ;;
        Raced)       printf 'the destination appeared mid-run' ;;
        *)           printf 'it did not complete' ;;
    esac
}

# list_folder_requests0 — NUL-delimited absolute paths of every empty depth-2
# directory under LR_ROOT.
#
# -mindepth 2 -maxdepth 2 IS the design, not an optimisation. Depth 1 is an artist
# directory and must never be a request: deleting a track is meant to leave its
# artist folder behind, so an empty artist folder has to mean nothing at all. It is
# also what keeps the cost flat — find never descends into a track folder, so the
# twelve files inside each are never even stat'd.
#
# rejected/ sits at depth 1, so ITS contents are at depth 2 and would otherwise
# read as requests. Excluded explicitly.
#
# NUL-delimited, never newline: a directory name can contain one, and a line-split
# list would leave such a request undrained forever.
list_folder_requests0() {
    find "$LR_ROOT" -mindepth 2 -maxdepth 2 -type d -empty \
         ! -path "${REJECTED_DIR}/*" \
         ! -path '*/.*' ! -path '*/.*/*' \
         -print0 2>/dev/null | sort -z
}

# write_failure_marker <track-dir> <reason> — record a terminal outcome INSIDE the
# request folder, which both stops it being re-queued (it is no longer empty) and
# leaves a durable, Syncthing-replicated explanation where the request was made.
#
# That second half is the point. Before this, a failure's only record was an ntfy
# notification: miss it and the request was gone with no trace on disk. The marker
# reaches every device, in the folder the thing was asked for.
#
# VISIBLE, not a dotfile. Both work mechanically — find -empty counts dotfiles —
# but a hidden marker leaves the folder looking empty in a file browser while the
# system considers it finished, and that discrepancy is a trap for whoever reads
# it six months later.
write_failure_marker() { # $1 = track directory, $2 = reason
    local dir="$1" reason="$2" f
    [[ -d "$dir" ]] || { log "  !! cannot mark ${dir}: not a directory"; return 1; }
    # ONLY an empty folder is marked, and this is a correctness rule rather than
    # tidiness. A non-empty folder is already not a request, so the marker's
    # mechanical job is done — and the one case that reaches here non-empty is
    # `Raced`, where the folder holds a PEER'S REAL RESULT. Writing a failure note
    # into someone else's twelve files would be vandalism dressed as a receipt.
    # The notification still reports it; the folder is left exactly as found.
    if [[ -n "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        log "  SKIP   marker for ${dir##*/}: the folder is no longer empty"
        return 0
    fi
    f="${dir}/${MARKER_PREFIX}${reason}.txt"
    if ! printf '%s\n\n%s\n%s\n\n%s\n' \
            "Liquidroom could not complete this request." \
            "Reason: ${reason}" \
            "When:   $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "Delete this file to try again." > "$f" 2>/dev/null; then
        log "  !! could not write marker into ${dir}"
        return 1
    fi
    return 0
}

# portable_rename_request <artist-dir> <raw-track-name> — echo the track name to
# use, renaming the directory first when portable_segment() would change it.
#
# THIS PREVENTS A SILENT INFINITE LOOP and has no analogue in the .txt design. A
# marker was consumed by name, so mapping "What Ever Happened?" to the portable
# "What Ever Happened_" at publish time was harmless. A request FOLDER is not
# consumed — it IS the destination — so publishing to the portable spelling would
# leave the original sitting there, still empty, still a request, every five
# minutes forever. Renaming in place makes request and destination the same path
# by construction.
#
# Returns 1 without renaming when the portable name is already taken; the caller
# marks the raw folder rather than merging two histories.
# Leading and trailing whitespace is trimmed here too, which parse_request() used
# to do for marker NAMES and which the folder model would otherwise lose. It is not
# cosmetic: Windows silently strips a trailing space or dot from a directory name,
# so "Smile Again " and "Smile Again" are the SAME folder on a peer and one of them
# would fail to create — the same class of stranding the "?" caused on legion.
portable_rename_request() { # $1 = artist dir, $2 = raw track basename
    local adir="$1" raw="$2" want
    want="${raw#"${raw%%[![:space:]]*}"}"; want="${want%"${want##*[![:space:]]}"}"
    want="$(portable_segment "$want")"
    [[ -n "$want" ]] || { log "  !! ${raw}: name is only whitespace"; return 1; }
    [[ "$want" != "$raw" ]] || { printf '%s' "$raw"; return 0; }
    if [[ -e "${adir}/${want}" ]]; then
        log "  !! ${raw}: portable name ${want} already exists"
        return 1
    fi
    if ! mv -T -- "${adir}/${raw}" "${adir}/${want}" 2>/dev/null; then
        log "  !! ${raw}: could not rename to ${want}"
        return 1
    fi
    log "  RENAME ${raw} -> ${want} (made portable)"
    printf '%s' "$want"
}

new_uuid() { cat /proc/sys/kernel/random/uuid; }

# --- model pins -------------------------------------------------------------
# Both separation models are torch checkpoints, i.e. arbitrary pickles, and both
# arrive over the network from third parties. The sha256 pins are the trust
# anchor; torch>=2.6's weights_only default and network_mode:none are the other
# two, and they only work together.
#
# The pins live HERE rather than in models.sh because two things need them:
# models.sh verifies what it fetches, and the triage re-verifies before every
# separation run. "Fetched once, therefore correct forever" is an assumption
# about a directory that a bind mount, a rebuild and a stray audio-separator
# download all write to; re-reading 1 GB costs about two seconds against a stage
# measured in half-hours.
#
# Columns: <filename> <sha256> <required|optional>.
#   BS-Roformer-SW.{ckpt,yaml} — REQUIRED. The .yaml is the architecture config:
#     pinning the weights while leaving the config free would still let someone
#     choose how those weights are loaded. Recorded 2026-08-19 from the copies
#     that have been producing stems on this box since 2026-08-14 — the
#     production-proven bytes are the pin, not a fresh download's.
#   listra92 pair — OPTIONAL, and deliberately so: the lead/rhythm split already
#     degrades to `ok_no_split` when MSST cannot run, and turning a documented
#     degradation into a dead batch would be a regression. Absent is fine;
#     present-and-wrong is not. Pins recorded from HuggingFace LFS metadata
#     2026-08-14.
# Overridable ONLY by the test suite (same seam as LR_ROOT).
MODEL_PINS="${MODEL_PINS-\
BS-Roformer-SW.ckpt 24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e required
BS-Roformer-SW.yaml b558996f1e25eb48798bd6502505a5de94c4f966d6edfb1a0420f06cc40b501a required
mbr_lead_rhythm_guitar_listra92.ckpt b3c47bca33609ca1ba0bb2d2076410bfd1eb941b051b72afc1f3e24d12b17eef optional
mbr_lead_rhythm_guitar_listra92_config.yaml a26685bc9ab10aab4dc153b74ec3559f1b4bd2251d129a13b6b22fe3a27d382d optional}"

# model_sha <filename> — the pinned digest, or empty if that file is not pinned.
model_sha() {
    local n s r
    while read -r n s r; do
        [[ "$n" == "$1" ]] && { printf '%s' "$s"; return 0; }
    done <<<"$MODEL_PINS"
    return 1
}

# verify_models — every pinned file that is PRESENT must match; every `required`
# one must also exist. Returns non-zero and logs each finding.
verify_models() {
    local n s r f bad=0
    while read -r n s r; do
        [[ -n "$n" ]] || continue
        f="${MODELS_DIR}/${n}"
        if [[ ! -f "$f" ]]; then
            if [[ "$r" == "required" ]]; then
                log "MODEL MISSING: ${n} — run: bash liquidroom/scripts/models.sh"
                bad=1
            fi
            continue
        fi
        if ! sha256sum -c --status <<<"${s}  ${f}"; then
            log "MODEL SHA256 MISMATCH: ${n} — refusing to load it"
            bad=1
        fi
    done <<<"$MODEL_PINS"
    (( bad == 0 ))
}

# --- candidates -------------------------------------------------------------

# Root entries only, dotfiles excluded (Syncthing scratch and macOS cruft).
# NUL-delimited, never newline: a filename CAN contain a newline, and a
# line-split list would leave such a marker undrained — which is a hot-loop.
# (valid_segment_lr rejects the newline later, so the file parks; but it has to
# survive listing intact to get there.) Symlinks are included ON PURPOSE — the
# triage parks them as strays, and a listing that skipped them would leave a
# symlinked *.txt at root re-firing the path unit forever.
list_requests0() {
    find "$LR_ROOT" -maxdepth 1 \( -type f -o -type l \) ! -name '.*' \
        -printf '%f\0' 2>/dev/null | sort -z
}

count_requests() {
    find "$LR_ROOT" -maxdepth 1 \( -type f -o -type l \) ! -name '.*' \
        -printf 'x' 2>/dev/null | wc -c
}

# --- Syncthing quiet gate ---------------------------------------------------
# Lives in syncthing/syncthing.lib.sh (sourced at the top) with pigeonhole's copy,
# including QUIET_WAIT_S / QUIET_POLL_S. The triage calls syncthing_quiet "$LR_ROOT":
# the API answers for the whole "master" folder, but the .tmp glob has to look at
# the directory this run is about to touch, and that is the only value the two
# pipelines ever disagreed about. lr_quiet() was the local name for it.

# --- ntfy -------------------------------------------------------------------
# Receipts only: done or failed, no buttons, no retraction. A liquidroom
# notification carries no outstanding decision, so nothing here needs the
# sequence-id/withdrawal machinery the intake pipelines carry.

# _load_env / ntfy_muted / notify moved to ntfy/ntfy.lib.sh (sourced at the top),
# unchanged. Four near-identical copies lived across the repo and had already
# drifted; this one was written correctly and is here to stop being the fifth.
#
# Nothing else is needed: liquidroom sends receipts, so it never tags a message with
# a sequence id and never retracts one. The shared notify() takes those arguments
# optionally, so the calls below are unchanged.
