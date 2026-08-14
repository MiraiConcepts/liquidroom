#!/bin/bash
# shellcheck disable=SC2034  # config vars are consumed by the scripts that source this
# Shared helpers for the liquidroom pipeline (request marker -> Soulseek download
# -> stems). Sourced by liquidroom.triage.sh — not executable on its own.
#
# No AI transport here: unlike documents/capture, this pipeline never talks to
# api.anthropic.com. ai.lib.sh is sourced ONLY for hdr_safe/md_escape — a
# notification title carries a filename synced in from another device, and those
# two sanitisers must not exist as a second drifting copy.

set -uo pipefail

# shellcheck source=/zpool/catallenya/ai/scripts/ai.lib.sh
source "/zpool/catallenya/ai/scripts/ai.lib.sh"

# Overridable ONLY so the test suite can run against a scratch tree — same seam
# as DOCS/STATE_DIR in documents.lib.sh. Never set in production; the defaults
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

# Batch cap. Bigger than documents' rationale would suggest because batching makes
# marginal tracks cheap (one model load per batch, not per track) — but the stage
# timeouts scale by N, so the cap is what keeps a huge drop inside TimeoutStartSec.
MAX_PER_RUN="${MAX_PER_RUN:-4}"

# Per-track stage budgets, multiplied by the batch size for the real timeout.
# Download: Sockseek walks up to 10 candidates on dead peers; 15 min covers a slow
# FLAC from a modem-grade peer. Process: 5–15 min typical for the SW pass on this
# CPU at overlap 2, plus the lead/rhythm split, plus mixes; 45 min is ~2x worst
# observed class. Both are ceilings, not estimates — a healthy run never sees them.
DL_TIMEOUT_S="${DL_TIMEOUT_S:-900}"
PROC_TIMEOUT_S="${PROC_TIMEOUT_S:-2700}"

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
# the globals and throw them away (st_api_base precedent in documents.lib.sh).
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

# Only the keys this pipeline needs, extracted rather than sourced — sourcing the
# root .env wholesale is arbitrary code execution if that file ever grows $(...).
_load_env() {
    local root_env="/zpool/catallenya/.env" k v line
    [[ -f "$root_env" ]] || { log "no .env"; return 1; }
    for k in TAILNET_DOMAIN TAILNET_DNS_NAME NTFY_REVERSE_PROXY_PORT; do
        line="$(grep -m1 "^${k}=" "$root_env" 2>/dev/null)" || continue
        v="${line#*=}"; v="${v%\"}"; v="${v#\"}"
        printf -v "$k" '%s' "$v"
    done
}

# Test seam. Placed immediately before the curl, not at the top, so header
# construction and hdr_safe still execute under test — only the wire call is
# suppressed. Never set in production. (documents.lib.sh precedent, learned the
# expensive way: a suite without it put dozens of pings on the live topic.)
ntfy_muted() { [[ "${NTFY_DISABLE:-}" == "1" ]]; }

notify() { # $1=title $2=priority $3=tags $4=body
    _load_env || { log "skipping notify"; return 0; }
    local url="https://${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}:${NTFY_REVERSE_PROXY_PORT}"
    # The title carries artist/track parsed from a filename that synced in from
    # another device — untrusted. hdr_safe strips the CR/LF that would otherwise
    # smuggle a second header.
    local -a hdr=(-H "Title: $(hdr_safe "$1")" -H "Tags: $3" -H "Markdown: yes")
    [[ -n "${2:-}" ]] && hdr+=(-H "Priority: $2")
    ntfy_muted && return 0
    # --data-raw, never -d: a body that begins with "@<path>" would otherwise be
    # read as a FILE to upload. The body's first line is usually a track name
    # somebody typed on another device.
    curl -sS "${hdr[@]}" \
         --data-raw "$(tail -c 3500 <<<"$4")" "${url}/${NTFY_TOPIC}" >/dev/null || true
}
