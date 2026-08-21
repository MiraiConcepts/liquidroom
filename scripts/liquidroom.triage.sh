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
#
# A third case sits between them: a request we understood perfectly and REFUSED
# to act on because the environment turned unsafe (a symlink planted at the
# destination mid-run, a model that no longer matches its pin). Its outcome is
# not decided — nothing was tried — so consuming it would charge the owner for
# someone else's tampering. Those park too, and moving the marker back out of
# rejected/ once the box is sane retries it verbatim.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/zpool/catallenya/liquidroom/scripts/liquidroom.lib.sh
source "${SELF_DIR}/liquidroom.lib.sh"

for _bin in jq curl flock docker timeout stat awk sed tr sha256sum; do
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
until syncthing_quiet "$LR_ROOT"; do
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
        line Stranded File "$name" "Reason: ${reason}"
    else
        log "  !! could not park ${name} — STILL AT ROOT, path unit will re-fire"
        line Stuck File "$name" "Reason: could not move it out of the root"
    fi
}

# Per-accepted-track parallel arrays, indexed by batch slot (1..N).
IDX=0
declare -A SEEN=()          # "artist/track" -> slot, catches duplicates in one batch
declare -a A_MARKER=() A_ARTIST=() A_TRACK=()
# Outcomes, grouped by VERB. One notification per verb present in the run, replacing
# the single summary this used to send — a run where two tracks published and one
# download failed cannot honestly be titled `Finished`, and the old solo title was
# `${LINES[0]%%:*}`, which put the raw outcome phrase in the title ("Liquidroom: stems
# ready") rather than anything from the contract.
#
# LINES stays as the flat list, because the truncation tail and the log still count
# the run as a whole. OUT_ORDER preserves first-seen order so the notifications arrive
# in the order things happened rather than in hash order.
declare -a LINES=()
declare -A OUT_BODY=() OUT_N=()
declare -a OUT_ORDER=()

# line <verb> <noun> <name> [detail] — record one track's outcome.
#
# The NAME is the item and the DETAIL is what happened to it, which is the shape
# body_list() renders. It used to be one string reading "download failed: Artist -
# Track — no candidate matched": the reason first, the name buried in the middle, and
# an em-dash the body language bans. The title already carries the verb, so the detail
# only has to say what the verb does not.
#
# NOT escaped here. body_list() escapes every line it renders, and the call sites used
# to md_escape by hand — doing both turns a track called `A_B` into `A\\_B`.
#
# The verb is the contract's; the noun is what the verb acts on, which is not always
# the track: a download that never arrived is a Download, a separation that died is a
# Separation. See ntfy/MESSAGES.md § 6.
line() {
    local verb="$1" noun="$2" text="$3${4:+$'\t'$4}" k="$1|$2"
    LINES+=("${text//$'\t'/ — }")
    # Keyed on verb AND noun, not verb alone: `Refused` covers a separator output
    # that failed a safety check (a Result) and a publish destination that did (a
    # Track), and both can happen in the same run. Keying on the verb would have
    # counted them together and titled the pair with whichever noun arrived first.
    if [[ -z "${OUT_N[$k]:-}" ]]; then
        OUT_ORDER+=("$k"); OUT_N[$k]=0; OUT_BODY[$k]=""
    fi
    OUT_N[$k]=$(( OUT_N[$k] + 1 ))
    OUT_BODY[$k]+="${OUT_BODY[$k]:+$'\n'}${text}"
}

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
    # A marker is EMPTY. A file with anything in it is a document someone
    # dropped in the wrong place — even at 40 bytes, and even when its name
    # happens to read as "Artist - Track.txt". See marker_is_content().
    if marker_is_content "$src"; then
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
        line Skipped Track "${artist} - ${track}" "Reason: it already exists"
        continue
    fi
    if [[ -n "${SEEN[${artist}/${track}]:-}" ]]; then
        rm -f -- "$src"
        log "  DUPE   ${name} (already queued this run)"
        line Skipped Track "${artist} - ${track}" "Reason: it is a duplicate request in this batch"
        continue
    fi

    IDX=$((IDX+1)); SEEN["${artist}/${track}"]="$IDX"
    A_MARKER[IDX]="$src"; A_ARTIST[IDX]="$artist"; A_TRACK[IDX]="$track"
    mkdir -p "${BATCH_DIR}/t${IDX}/dl"
    printf '%s\t%s\t%s\n' "$IDX" "$artist" "$track" >> "${BATCH_DIR}/spec.tsv"
    log "  QUEUE  [${IDX}] ${artist} - ${track}"
done

# decide <idx> <verb> <noun> <name> [detail] — a queued track's outcome is now known:
# consume its marker and record the outcome under its verb. rm -f tolerates a marker
# the owner already deleted on another device mid-run.
decide() { rm -f -- "${A_MARKER[$1]}"; line "$2" "$3" "$4" "${5:-}"; }

# refuse <idx> <log-detail> <verb> <noun> <name> [detail] — a queued track we will NOT act on
# because the box became unsafe, not because the request failed. The marker is
# PARKED rather than consumed (see the header): nothing was attempted, so the
# request is still exactly as valid as when it was typed, and destroying it
# would make a planted symlink or a swapped checkpoint cost the owner their
# request as well. A park failure is loud for the same reason park_stray's is.
refuse() {
    local i="$1" src name
    src="${A_MARKER[$i]}"; name="${src##*/}"
    log "  REFUSE [${i}] $2"
    if park "$src" "$name"; then
        line "$3" "$4" "$5" "${6:-}"
    else
        log "  !! could not park ${name} — STILL AT ROOT, path unit will re-fire"
        line Stuck File "$name" "Reason: could not move it out of the root"
    fi
}

# dl_size_hint <idx> -> " (43 MB)" for the downloaded file, or "" if unreadable.
# Size is the cheapest quality signal there is: a 40 MB FLAC and a 4 MB mp3 for
# the same song are instantly distinguishable, without probing codecs.
dl_size_hint() {
    local f sz
    f="$(find "${BATCH_DIR}/t${1}/dl" -maxdepth 1 -type f -print -quit 2>/dev/null)"
    [[ -n "$f" ]] || return 0
    sz="$(stat -c %s -- "$f" 2>/dev/null)" || return 0
    printf 'Size: %s MB' "$(( sz / 1048576 ))"
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
    # -k 30: TERM asks the compose CLIENT to stop, and a client wedged on the
    # docker socket ignores it — without the follow-up KILL the `timeout` that
    # was supposed to bound this stage waits forever itself, and the only thing
    # left holding the run is TimeoutStartSec, which cannot see the container.
    timeout -k 30 "$(( DL_TIMEOUT_S * IDX ))" \
        docker compose -f "$COMPOSE_FILE" run --rm --name liquidroom-job \
        --service-ports -e SLSK_USER -e SLSK_PASS \
        liquidroom-soulseek download "$BATCH_ID" > "${BATCH_DIR}/download.log" 2>&1 || rc=$?
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
            # "name<TAB>Size: 43 MB", which body_list renders indented beneath the
            # name. NOT md_escape'd here — body_list escapes what it renders, and
            # doing both turns Aphex_Twin into Aphex\\_Twin.
            GOT+=("${d:-${A_TRACK[$i]} - ${A_ARTIST[$i]}}"$'\t'"$(dl_size_hint "$i")")
        else
            d="$(manifest_detail dl "$i")"
            log "  FAIL   [${i}] download: ${d:-no result}"
            decide "$i" Dropped Download "${A_ARTIST[$i]} - ${A_TRACK[$i]}" "${d:+Reason: ${d}}"
        fi
    done

    # INTERIM PING. Separation is ~9.4x realtime on this box, so without this the
    # first half hour is silent and a wrong match stays invisible until it is
    # already paid for. Deliberately informational: nothing to tap, nothing
    # outstanding — knowing early is the entire value, and re-requesting is the
    # remedy. Suppressed when NOTHING downloaded, because then the final summary
    # is seconds away and a second message is pure noise.
    if (( ${#GOT[@]} > 0 )); then
        # ITEMS, then FACTS, then PROSE — the order rule, enforced by body_join.
        #
        # The two lines here used to be italic asides reading "_2 not found — details
        # in the next message_" and "_Separating now — about 70 min._". Neither is a
        # truncation, which is the one thing italics mean; both are states of the run,
        # which is what a fact is. And a fact must read as a complete statement, so it
        # is `Estimated time left: 70m` rather than the `about 70m` that a no-labels
        # rule read literally would produce. See ntfy/MESSAGES.md § 3.
        notfound=$(( IDX - ${#GOT[@]} ))
        facts=("Separating now")
        # ETA from the measured rate, floored at the observed ~31min minimum.
        facts+=("Estimated time left: $(( ${#GOT[@]} * 35 ))m")
        (( notfound > 0 )) && facts+=("${notfound} track$( (( notfound == 1 )) || printf s ) not found")
        log "  notified download of ${#GOT[@]}"
        notify_receipt "$(title_count Downloaded "${#GOT[@]}" Track)" \
            "$(body_join \
                "$(body_list "${GOT[@]}")" \
                "$(body_fact "${facts[@]}")" \
                "$( (( notfound > 0 )) && printf 'Details are in the next message.' )")"
    fi
fi

# --- stage 2: separate + split + mix, ONE container, model loads once --------

declare -a PUBLISHABLE=()
if (( ${#SURVIVORS[@]} > 0 )) && ! verify_models; then
    # The only consumer of the checkpoints is the stage below, so this is the
    # last moment the pins can still prevent a swapped pickle from being loaded.
    # Refuse rather than fail: the requests are innocent (see refuse()).
    for i in "${SURVIVORS[@]}"; do
        refuse "$i" "model verification failed" Refused Track \
            "${A_ARTIST[$i]} - ${A_TRACK[$i]}" "Reason: the models failed verification"
    done
    SURVIVORS=()
fi
if (( ${#SURVIVORS[@]} > 0 )); then
    n="${#SURVIVORS[@]}"
    log "process: ${n} track(s), one container, budget $(( PROC_TIMEOUT_S * n ))s"
    rc=0
    # A compose client that died with its container still registered leaves the
    # NAME claimed, and `run --name liquidroom-job` then refuses to start —
    # which would decide every survivor "separation failed" for a reason that
    # has nothing to do with them. Same shape as the entry cleanup above; the
    # EXIT trap covers the paths that never reach here.
    docker rm -f liquidroom-job >/dev/null 2>&1 || true
    timeout -k 30 "$(( PROC_TIMEOUT_S * n ))" \
        docker compose -f "$COMPOSE_FILE" run --rm --name liquidroom-job \
        liquidroom-roformer process "$BATCH_ID" > "${BATCH_DIR}/process.log" 2>&1 || rc=$?
    (( rc != 0 )) && log "process container exited rc=${rc} (124 = stage timeout)"

    for i in "${SURVIVORS[@]}"; do
        st="$(manifest_status proc "$i")"
        case "$st" in
            ok|ok_no_split) PUBLISHABLE+=("$i") ;;
            *)  d="$(manifest_detail proc "$i")"
                log "  FAIL   [${i}] process: ${d:-unknown}"
                # Work dir survives for autopsy; the stale purge collects it later.
                decide "$i" Halted Separation "${A_ARTIST[$i]} - ${A_TRACK[$i]}" "${d:+Reason: ${d}}"
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
        decide "$i" Refused Result "${artist} - ${track}" "Reason: the separator's result was unsafe"
        continue
    fi
    if [[ ! -d "$pub" ]] || ! compgen -G "${pub}/*" >/dev/null; then
        log "  FAIL   [${i}] publish: manifest ok but ${pub} is empty"
        decide "$i" Emptied Result "${artist} - ${track}" "Reason: the separator produced nothing"
        continue
    fi
    if find "$pub" -type l -print -quit 2>/dev/null | grep -q .; then
        log "  FAIL   [${i}] publish: symlink inside result — refusing"
        decide "$i" Refused Result "${artist} - ${track}" "Reason: a symlink was in the separator's result"
        continue
    fi
    # `-e`/`-L` catches the common case with a clear message; `mv -T` closes the
    # residual TOCTOU — if a dest syncs in from a peer between the check and the
    # move, -T turns what would be a nested move (dest/publish/...) into a plain
    # error, so the worst case is a clean per-track failure, never a bad publish.
    if [[ -e "$dest" || -L "$dest" ]]; then
        log "  FAIL   [${i}] publish: destination appeared during processing"
        decide "$i" Raced Track "${artist} - ${track}" "Reason: the destination appeared mid-run, left unpublished"
        continue
    fi
    # The PARENT is checked here and not only at queue time, because half an hour
    # of separation sits between the two and the root is a Syncthing folder: a
    # peer can create "<artist> -> /etc" in that window, and `mkdir -p` follows
    # an existing symlink without complaint, so the mv below would land the stems
    # wherever it points — and then sync that back out to every device. The
    # queue-time valid_segment_lr/under_root pair, mv -T, and ProtectSystem=
    # strict on the unit are the other three defences; this is the peer-side,
    # time-of-use one none of them can cover.
    if [[ -L "${LR_ROOT}/${artist}" ]]; then
        refuse "$i" "publish: artist directory is a symlink" Refused Track \
            "${artist} - ${track}" "Reason: the destination was unsafe"
        continue
    fi
    # ...and re-resolve the whole path, in case the symlink is further up. -m
    # tolerates the leaf not existing yet; every existing component IS resolved,
    # so a symlinked parent that slipped past the check above still lands
    # outside LR_ROOT here.
    if ! under_root "$dest"; then
        refuse "$i" "publish: destination resolves outside the root" Refused Track \
            "${artist} - ${track}" "Reason: the destination was unsafe"
        continue
    fi
    if mkdir -p "${LR_ROOT}/${artist}" 2>/dev/null && mv -T -- "$pub" "$dest" 2>/dev/null; then
        st="$(manifest_status proc "$i")"
        suffix=""
        [[ "$st" == "ok_no_split" ]] && suffix="Note: the lead/rhythm split was unavailable"
        log "  DONE   [${i}] ${artist}/${track}${suffix:+ (${suffix})}"
        decide "$i" Finished Track "${artist} - ${track}" "$suffix"
        rm -rf -- "${BATCH_DIR}/t${i}"
    else
        log "  FAIL   [${i}] publish: could not move into place"
        decide "$i" Unpublished Track "${artist} - ${track}" "Reason: it could not be moved into place"
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

# --- one notification per VERB present in the run ----------------------------
# This replaced a single summary on 2026-08-20. A run where two tracks published and
# one download failed was titled `Finished` regardless, and the solo case put the raw
# outcome phrase in the title — `${LINES[0]%%:*}` yielded "Liquidroom: stems ready",
# which is neither the contract's grammar nor the track's name.
#
# Bounded by MAX_PER_RUN=3, so at most three distinct failure verbs. A typical run is
# two notifications (the interim Downloaded, then Finished); a bad one is four. These
# are RECEIPTS — no sequence id, no actions, nothing to retract — so multiplying them
# adds no lifecycle logic, which is the only reason it is safe to.
#
# The truncation tail rides on the LAST message rather than being repeated on each:
# it is a fact about the run, not about any one outcome.
for k in "${OUT_ORDER[@]:-}"; do
    [[ -n "$k" ]] || continue
    verb="${k%%|*}"; noun="${k##*|}"
    # The hand-rolled numbering that used to live here — and the comment explaining
    # the escaped `1\.`, which this file and pigeonhole each carried a copy of — is
    # body_list's job now. That escape is not cosmetic: the Android app renders REAL
    # ordered-list markers as unnumbered dots, so the numbers silently vanish.
    items=()
    while IFS= read -r l; do
        [[ -n "$l" ]] || continue
        items+=("$l")
    done <<<"${OUT_BODY[$k]}"
    # One of the three things italics mean, so it goes through body_aside.
    tail=""
    [[ "$k" == "${OUT_ORDER[-1]}" && "$TRUNCATED" -gt 0 ]] \
        && tail="$(body_aside "${TRUNCATED} more still queued")"
    notify_receipt "$(title_count "$verb" "${OUT_N[$k]}" "$noun")" \
        "$(body_join "$(body_list "${items[@]}")" "$tail")"
done
(( ${#LINES[@]} > 0 )) && log "notified ${#OUT_ORDER[@]} outcome group(s), ${#LINES[@]} line(s)"

exit 0
