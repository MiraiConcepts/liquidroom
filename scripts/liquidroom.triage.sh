#!/bin/bash
# liquidroom.triage.sh — drop an empty file named "Artist - Track.txt" at the root
# of master/liquidroom, get the track's stems back in <Artist>/<Track>/.
#
# Fired by liquidroom.triage.path the moment a marker lands. Drains the whole
# root in ONE batched run, then exits: one download container for every queued
# request, one processing container for every downloaded track (the model loads
# once per batch, which is what makes queueing several requests cheap).
#
# HARD INVARIANT — every file MUST leave the root before this script exits, on
# every branch, success or failure. PathExistsGlob re-fires for as long as a file
# remains, so a leftover marker hot-loops systemd. Same invariant as the other
# two intake pipelines, learned the same way. The split that keeps it safe:
#
#   PARKED  (mv -> rejected/)  anything we cannot READ AS A REQUEST: wrong
#           extension, a symlink, a file with real content, a name that does not
#           parse or does not survive the path-safety checks. Parking never
#           destroys data; rejected/ is in the synced tree and never auto-emptied.
#   DELETED (rm)               a marker we fully understood, once its outcome is
#           decided: published, failed, already-exists, duplicate. An understood
#           marker is a consumed command, and its disappearance from every synced
#           device IS the receipt.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/zpool/catallenya/liquidroom/scripts/liquidroom.lib.sh
source "${SELF_DIR}/liquidroom.lib.sh"

for _bin in jq curl flock docker timeout stat awk; do
    command -v "$_bin" >/dev/null || die "missing required command: ${_bin}"
done
: "${SLSK_USER:?SLSK_USER not set (EnvironmentFile=/etc/liquidroom.env)}"
: "${SLSK_PASS:?SLSK_PASS not set (EnvironmentFile=/etc/liquidroom.env)}"

mkdir -p "$STATE_DIR" "$WORK_DIR" "$MODELS_DIR" "$LR_ROOT" "$REJECTED_DIR"

# Serialise. A running batch must not overlap the next .path fire — and one
# separation at a time is also the right CPU policy on this box.
exec 9>"$LOCK_FILE"
flock -n 9 || { log "another triage holds the lock; exiting"; exit 0; }

# The job container runs in dockerd's cgroup, not this unit's, so TimeoutStartSec
# alone cannot kill it. Three layers instead: per-stage `timeout` around the
# client (compose proxies TERM into the container), a FIXED container name so a
# survivor from a killed run is findable, and this cleanup at entry + exit.
if docker rm -f liquidroom-job >/dev/null 2>&1; then
    log "removed stale liquidroom-job container from a previous run"
fi
cleanup() { docker rm -f liquidroom-job >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Failure autopsies keep their work dirs for WORK_KEEP_DAYS, then go here.
find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+${WORK_KEEP_DAYS}" \
     -exec rm -rf {} + 2>/dev/null

# --- wait for Syncthing, gather the batch -----------------------------------

waited=0
until lr_quiet; do
    (( waited >= QUIET_WAIT_S )) && { log "syncthing still busy after ${waited}s; leaving root for the next fire"; exit 0; }
    sleep "$QUIET_POLL_S"; waited=$((waited + QUIET_POLL_S))
done

mapfile -d '' -t CANDS < <(list_requests0)
(( ${#CANDS[@]} )) || { log "nothing at root"; exit 0; }

TRUNCATED=0
if (( ${#CANDS[@]} > MAX_PER_RUN )); then
    TRUNCATED=$(( ${#CANDS[@]} - MAX_PER_RUN ))
    log "CAP: ${#CANDS[@]} at root, taking ${MAX_PER_RUN}, deferring ${TRUNCATED} to the next run"
    CANDS=("${CANDS[@]:0:$MAX_PER_RUN}")
fi
log "draining ${#CANDS[@]} file(s) from root"

# park <src> <basename> — move a non-request out of the root without destroying
# it. Never clobbers: a name collision in rejected/ gets -2, -3, ... mv -n so
# even a same-name file racing in cannot be overwritten (parity with documents).
park() {
    local src="$1" name="$2" stem ext dest n=2
    stem="${name%.*}"; ext="${name##*.}"
    [[ "$stem" == "$name" ]] && ext=""   # no extension at all
    dest="${REJECTED_DIR}/${name}"
    while [[ -e "$dest" ]]; do
        dest="${REJECTED_DIR}/${stem}-${n}${ext:+.$ext}"; n=$((n+1))
    done
    mv -n -- "$src" "$dest" 2>/dev/null && [[ ! -e "$src" ]]
}

# park_stray <src> <name> <reason-for-the-phone> — park and record the outcome.
# A park FAILURE must be loud, not swallowed: the file stays at root and the
# .path unit re-fires, so the operator and the phone need to hear it rather than
# discover a wedged unit later. (The end-of-run invariant assert catches the
# spin; this makes the cause visible.)
park_stray() {
    local src="$1" name="$2" reason="$3"
    if park "$src" "$name"; then
        log "  PARK   ${name} (${reason})"
        line "parked (${reason}): $(md_escape "$name")"
    else
        log "  !! could not park ${name} — STILL AT ROOT, path unit will re-fire"
        line "could not move stray, still at root: $(md_escape "$name")"
    fi
}

# Per-accepted-track parallel arrays, indexed by batch slot (1..N).
IDX=0
declare -A SEEN=()          # "artist/track" -> slot, catches duplicates in one batch
declare -a A_MARKER=() A_ARTIST=() A_TRACK=()
# Result lines for the single summary notification, built as outcomes decide.
declare -a LINES=()
line() { LINES+=("$1"); }

BATCH_ID="$(new_uuid)"
BATCH_DIR="${WORK_DIR}/${BATCH_ID}"
mkdir -p "$BATCH_DIR"

for name in "${CANDS[@]}"; do
    src="${LR_ROOT}/${name}"
    # A symlink is nothing this pipeline creates and nothing a phone syncs in —
    # and following one would read or move whatever it points at. Park the LINK.
    if [[ -L "$src" ]]; then
        park_stray "$src" "$name" "symlink"
        continue
    fi
    [[ -f "$src" ]] || continue          # vanished under us; nothing to drain

    if [[ "${name,,}" != *.txt ]]; then
        park_stray "$src" "$name" "not a request"
        continue
    fi
    size="$(stat -c %s -- "$src" 2>/dev/null || echo 0)"
    if (( size > MARKER_MAX_BYTES )); then
        park_stray "$src" "$name" "real file, not a marker"
        continue
    fi

    if ! parse_request "$name"; then
        park_stray "$src" "$name" "name needs to be 'Artist - Track.txt'"
        continue
    fi
    artist="$PARSED_ARTIST"; track="$PARSED_TRACK"

    if ! valid_segment_lr "$artist" || ! valid_segment_lr "$track" \
       || ! under_root "${LR_ROOT}/${artist}/${track}"; then
        park_stray "$src" "$name" "unsafe name"
        continue
    fi

    if [[ -e "${LR_ROOT}/${artist}/${track}" ]]; then
        rm -f -- "$src"
        log "  SKIP   ${name} (already exists)"
        line "already exists: $(md_escape "${artist} - ${track}")"
        continue
    fi
    if [[ -n "${SEEN[${artist}/${track}]:-}" ]]; then
        rm -f -- "$src"
        log "  DUPE   ${name} (already queued this run)"
        line "duplicate request dropped: $(md_escape "${artist} - ${track}")"
        continue
    fi

    IDX=$((IDX+1)); SEEN["${artist}/${track}"]="$IDX"
    A_MARKER[IDX]="$src"; A_ARTIST[IDX]="$artist"; A_TRACK[IDX]="$track"
    mkdir -p "${BATCH_DIR}/t${IDX}/dl"
    printf '%s\t%s\t%s\n' "$IDX" "$artist" "$track" >> "${BATCH_DIR}/spec.tsv"
    log "  QUEUE  [${IDX}] ${artist} - ${track}"
done

# decide <idx> <line-text> — a queued track's outcome is now known: consume its
# marker and record the summary line. rm -f tolerates a marker the owner already
# deleted on another device mid-run.
decide() { rm -f -- "${A_MARKER[$1]}"; line "$2"; }

# dl_size_hint <idx> -> " (43 MB)" for the downloaded file, or "" if unreadable.
# Size is the cheapest quality signal there is: a 40 MB FLAC and a 4 MB mp3 for
# the same song are instantly distinguishable, without probing codecs.
dl_size_hint() {
    local f sz
    f="$(find "${BATCH_DIR}/t${1}/dl" -maxdepth 1 -type f -print -quit 2>/dev/null)"
    [[ -n "$f" ]] || return 0
    sz="$(stat -c %s -- "$f" 2>/dev/null)" || return 0
    printf ' (%s MB)' "$(( sz / 1048576 ))"
}

# manifest_status <stage> <idx> -> last recorded status for that slot+stage
manifest_status() {
    awk -F'\t' -v s="$1" -v i="$2" '$1==i && $2==s {st=$3} END{print st}' \
        "${BATCH_DIR}/manifest.tsv" 2>/dev/null
}
manifest_detail() {
    awk -F'\t' -v s="$1" -v i="$2" '$1==i && $2==s {d=$4} END{print d}' \
        "${BATCH_DIR}/manifest.tsv" 2>/dev/null
}

# --- stage 1: download the whole batch in ONE container ----------------------

declare -a SURVIVORS=()
if (( IDX > 0 )); then
    log "download: ${IDX} track(s), one container, budget $(( DL_TIMEOUT_S * IDX ))s"
    rc=0
    # --service-ports publishes 50300 for peer connections — download stage only.
    # SLSK creds are forwarded NAME-ONLY: the values never appear on any argv.
    # Container stdout/err lands in the batch dir, not /dev/null: --rm deletes the
    # container and its `docker logs` with it, so this file is the only autopsy.
    timeout "$(( DL_TIMEOUT_S * IDX ))" \
        docker compose -f "$COMPOSE_FILE" run --rm --name liquidroom-job \
        --service-ports -e SLSK_USER -e SLSK_PASS \
        liquidroom download "$BATCH_ID" > "${BATCH_DIR}/download.log" 2>&1 || rc=$?
    (( rc != 0 )) && log "download container exited rc=${rc} (124 = stage timeout)"
    # This log is kept WORK_KEEP_DAYS for autopsy, and Sockseek may print its own
    # login line. Scrub the credentials before they persist — literal (quoted)
    # replacement, so a password full of regex metacharacters is handled safely.
    if [[ -f "${BATCH_DIR}/download.log" ]]; then
        _dl="$(< "${BATCH_DIR}/download.log")"
        _dl="${_dl//"$SLSK_PASS"/[redacted]}"
        _dl="${_dl//"$SLSK_USER"/[redacted]}"
        printf '%s\n' "$_dl" > "${BATCH_DIR}/download.log"
        unset _dl
    fi

    # Per-track download outcomes, and the lines for the interim ping below.
    declare -a GOT=()
    for i in $(seq 1 "$IDX"); do
        st="$(manifest_status dl "$i")"
        if [[ "$st" == "ok" ]]; then
            SURVIVORS+=("$i")
            d="$(manifest_detail dl "$i")"
            # The FILENAME is the whole point of this ping: a live take, a remix
            # or the wrong artist is obvious at a glance, and .flac vs .mp3 says
            # what quality was found. Sized as a hint, not a decision.
            GOT+=("$(md_escape "${d:-${A_TRACK[$i]} - ${A_ARTIST[$i]}}")$(dl_size_hint "$i")")
        else
            d="$(manifest_detail dl "$i")"
            log "  FAIL   [${i}] download: ${d:-no result}"
            decide "$i" "download failed: $(md_escape "${A_ARTIST[$i]} - ${A_TRACK[$i]}")${d:+ — $(md_escape "$d")}"
        fi
    done

    # INTERIM PING. Separation is ~9.4x realtime on this box, so without this the
    # first half hour is silent and a wrong match stays invisible until it is
    # already paid for. Deliberately informational: nothing to tap, nothing
    # outstanding — knowing early is the entire value, and re-requesting is the
    # remedy. Suppressed when NOTHING downloaded, because then the final summary
    # is seconds away and a second message is pure noise.
    if (( ${#GOT[@]} > 0 )); then
        body=""; n=0
        for g in "${GOT[@]}"; do n=$((n+1)); body+="${n}\\. ${g}"$'\n'; done
        (( IDX > ${#GOT[@]} )) && body+=$'\n'"_$(( IDX - ${#GOT[@]} )) not found — details in the next message_"$'\n'
        # ETA from the measured rate, floored at the observed ~31min minimum.
        body+=$'\n'"_Separating now — about $(( ${#GOT[@]} * 35 )) min._"
        log "  notified download of ${#GOT[@]}"
        notify "Liquidroom: downloaded ${#GOT[@]}" "" inbox_tray "$body"
    fi
fi

# --- stage 2: separate + split + mix, ONE container, model loads once --------

declare -a PUBLISHABLE=()
if (( ${#SURVIVORS[@]} > 0 )); then
    n="${#SURVIVORS[@]}"
    log "process: ${n} track(s), one container, budget $(( PROC_TIMEOUT_S * n ))s"
    rc=0
    timeout "$(( PROC_TIMEOUT_S * n ))" \
        docker compose -f "$COMPOSE_FILE" run --rm --name liquidroom-job \
        liquidroom-offline process "$BATCH_ID" > "${BATCH_DIR}/process.log" 2>&1 || rc=$?
    (( rc != 0 )) && log "process container exited rc=${rc} (124 = stage timeout)"

    for i in "${SURVIVORS[@]}"; do
        st="$(manifest_status proc "$i")"
        case "$st" in
            ok|ok_no_split) PUBLISHABLE+=("$i") ;;
            *)  d="$(manifest_detail proc "$i")"
                log "  FAIL   [${i}] process: ${d:-unknown}"
                # Work dir survives for autopsy; the stale purge collects it later.
                decide "$i" "separation failed: $(md_escape "${A_ARTIST[$i]} - ${A_TRACK[$i]}")${d:+ — $(md_escape "$d")}"
                ;;
        esac
    done
fi

# --- stage 3: publish — one atomic rename per track --------------------------

for i in "${PUBLISHABLE[@]}"; do
    artist="${A_ARTIST[$i]}"; track="${A_TRACK[$i]}"
    pub="${BATCH_DIR}/t${i}/publish"
    dest="${LR_ROOT}/${artist}/${track}"
    # The processing container is semi-trusted — it runs a community model
    # checkpoint (an arbitrary pickle) under network_mode:none precisely because
    # a compromise is in scope. `publish/` is its writable bind mount, and this
    # mv is its ONLY path into the synced tree (the tree is not mounted into it).
    # So before the mv:
    #   - pub must be a real directory, not a symlink to one (mv of a symlink
    #     would rename the LINK into the tree, e.g. publish -> /etc syncing /etc
    #     to every device);
    #   - no entry underneath may be a symlink (publish/cover.jpg -> /zpool/.env
    #     would be carried in verbatim);
    #   - a manifest that says ok with an empty dir is a lying container.
    if [[ -L "$pub" ]]; then
        log "  FAIL   [${i}] publish: result dir is a symlink — refusing"
        decide "$i" "internal error (unsafe result): $(md_escape "${artist} - ${track}")"
        continue
    fi
    if [[ ! -d "$pub" ]] || ! compgen -G "${pub}/*" >/dev/null; then
        log "  FAIL   [${i}] publish: manifest ok but ${pub} is empty"
        decide "$i" "internal error (empty result): $(md_escape "${artist} - ${track}")"
        continue
    fi
    if find "$pub" -type l -print -quit 2>/dev/null | grep -q .; then
        log "  FAIL   [${i}] publish: symlink inside result — refusing"
        decide "$i" "internal error (symlink in result): $(md_escape "${artist} - ${track}")"
        continue
    fi
    # `-e`/`-L` catches the common case with a clear message; `mv -T` closes the
    # residual TOCTOU — if a dest syncs in from a peer between the check and the
    # move, -T turns what would be a nested move (dest/publish/...) into a plain
    # error, so the worst case is a clean per-track failure, never a bad publish.
    if [[ -e "$dest" || -L "$dest" ]]; then
        log "  FAIL   [${i}] publish: destination appeared during processing"
        decide "$i" "destination appeared mid-run, left unpublished: $(md_escape "${artist} - ${track}")"
        continue
    fi
    if mkdir -p "${LR_ROOT}/${artist}" 2>/dev/null && mv -T -- "$pub" "$dest" 2>/dev/null; then
        st="$(manifest_status proc "$i")"
        suffix=""
        [[ "$st" == "ok_no_split" ]] && suffix=" (lead/rhythm split unavailable)"
        log "  DONE   [${i}] ${artist}/${track}${suffix}"
        decide "$i" "stems ready: $(md_escape "${artist} - ${track}")${suffix}"
        rm -rf -- "${BATCH_DIR}/t${i}"
    else
        log "  FAIL   [${i}] publish: could not move into place"
        decide "$i" "publish failed (filesystem): $(md_escape "${artist} - ${track}")"
    fi
done

# Batch dir goes when every slot resolved cleanly; otherwise it stays for autopsy.
if ! compgen -G "${BATCH_DIR}/t*" >/dev/null; then
    rm -rf -- "$BATCH_DIR"
fi

# --- the invariant, asserted rather than trusted ------------------------------
left="$(count_requests)"
(( left <= TRUNCATED )) \
    || log "  !! $(( left - TRUNCATED )) file(s) STILL AT ROOT beyond the cap — path unit will spin"
(( TRUNCATED > 0 )) && log "  ${TRUNCATED} deferred; the path unit will re-fire for them"

# --- one summary notification per run ----------------------------------------
if (( ${#LINES[@]} > 0 )); then
    body=""
    n=0
    for l in "${LINES[@]}"; do
        n=$((n+1))
        # Literal "1\." — the Android app renders real ordered-list markers as
        # unnumbered dots (documents batch_list precedent, seen on the device).
        body+="${n}\\. ${l}"$'\n'
    done
    (( TRUNCATED > 0 )) && body+=$'\n'"_${TRUNCATED} more still queued_"$'\n'
    if (( ${#LINES[@]} == 1 )); then
        # Solo request: the one line IS the story, put it in the title.
        notify "Liquidroom: ${LINES[0]%%:*}" "" musical_note "$body"
    else
        notify "Liquidroom: ${#LINES[@]} requests" "" musical_note "$body"
    fi
fi

exit 0
