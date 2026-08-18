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

# A request marker is an empty file whose NAME is the request. Anything with real
# content is not a marker — someone dropped an actual file here by mistake, and
# deleting it would destroy data, so it goes to rejected/ instead.
MARKER_MAX_BYTES="${MARKER_MAX_BYTES:-4096}"

# Stale work dirs survive this long for failure autopsies, then are purged at the
# start of the next run. Matches capture's PRUNE_IMAGE_AFTER_DAYS spirit.
WORK_KEEP_DAYS="${WORK_KEEP_DAYS:-7}"

# How long to wait for Syncthing to go quiet before giving up. The .path unit
# re-fires while a marker remains, so giving up is a retry, not a loss.
QUIET_WAIT_S="${QUIET_WAIT_S:-180}"
QUIET_POLL_S=15

NTFY_TOPIC="liquidroom"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# --- request parsing --------------------------------------------------------

# parse_request <marker-basename> — sets PARSED_ARTIST / PARSED_TRACK globals.
# Split on the FIRST " - ": "Daft Punk - One More Time - Live" is artist
# "Daft Punk", track "One More Time - Live". Whitespace-trimmed; both halves
# must survive the trim. Must NOT be called via $(...) — a subshell would set
# the globals and throw them away (st_api_base precedent in pigeonhole.lib.sh).
PARSED_ARTIST=""; PARSED_TRACK=""
parse_request() {
    local stem="$1"
    PARSED_ARTIST=""; PARSED_TRACK=""
    stem="${stem%.[tT][xX][tT]}"
    [[ "$stem" == *" - "* ]] || return 1
    local artist="${stem%% - *}" track="${stem#* - }"
    # trim leading/trailing whitespace on both halves
    artist="${artist#"${artist%%[![:space:]]*}"}"; artist="${artist%"${artist##*[![:space:]]}"}"
    track="${track#"${track%%[![:space:]]*}"}";   track="${track%"${track##*[![:space:]]}"}"
    [[ -n "$artist" && -n "$track" ]] || return 1
    PARSED_ARTIST="$artist"; PARSED_TRACK="$track"
}

# Path safety. Deliberately NOT documents' valid_segment(): that allowlist bounds
# model-emitted free text to lowercase ASCII, and this pipeline's inputs are
# owner-authored song titles — the existing liquid-room library is full of
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

new_uuid() { cat /proc/sys/kernel/random/uuid; }

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
# Same folder as documents: master/liquidroom sits INSIDE the "master" Syncthing
# folder, so the same folder id answers for both pipelines.

SYNCTHING_CONFIG="/zpool/catallenya/syncthing/data/config/config.xml"
SYNCTHING_FOLDER_ID="3j1oy-9cefl"   # label "master"

lr_quiet() {
    compgen -G "${LR_ROOT}/.syncthing.*.tmp" >/dev/null 2>&1 && return 1
    # Test seam — a scratch tree has no Syncthing to ask. Never set in production.
    [[ "${SKIP_SYNCTHING_GATE:-}" == "1" ]] && return 0
    st_folder_idle
}

st_apikey() {
    [[ -r "$SYNCTHING_CONFIG" ]] || die "cannot read $SYNCTHING_CONFIG"
    grep -oPm1 '(?<=<apikey>)[^<]+' "$SYNCTHING_CONFIG"
}

# Through Caddy on loopback with the correct SNI — the container's :8384 is
# exposed but not published, and its bridge IP moves on every `compose up`.
# Sets ST_HOST/ST_PORT/ST_BASE as globals; must NOT be called via $(...).
ST_HOST=""; ST_PORT=""; ST_BASE=""
st_api_base() {
    local root_env="/zpool/catallenya/.env"
    [[ -f "$root_env" ]] || { log "no .env"; return 1; }
    # shellcheck source=/dev/null  # runtime-only file, not in the repo
    source "$root_env"
    ST_HOST="${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}"
    ST_PORT="${SYNCTHING_REVERSE_PROXY_PORT}"
    ST_BASE="https://${ST_HOST}:${ST_PORT}"
}

st_folder_idle() {
    local key json state need
    key="$(st_apikey)" || return 1
    st_api_base || return 1
    json="$(curl -sS --max-time 15 --resolve "${ST_HOST}:${ST_PORT}:127.0.0.1" \
            -H "X-API-Key: ${key}" \
            "${ST_BASE}/rest/db/status?folder=${SYNCTHING_FOLDER_ID}" 2>/dev/null)" || return 1
    state="$(jq -r '.state // "unknown"' <<<"$json" 2>/dev/null)"
    need="$(jq -r '.needFiles // 1' <<<"$json" 2>/dev/null)"
    [[ "$state" == "idle" && "$need" == "0" ]]
}

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
