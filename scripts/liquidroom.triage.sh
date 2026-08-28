#!/bin/bash
# liquidroom.triage.sh — create an empty folder at <Artist>/<Track>/ under
# master/liquidroom, get that track's stems back in the same folder.
#
# Polled by liquidroom.triage.timer every 5 minutes. A request is an EMPTY
# DIRECTORY, and that is why this polls rather than watching: no .path verb can
# express emptiness (see the timer for the full argument). Drains everything
# requested in ONE batched run, then exits — one download container for every
# queued request, one processing container for every downloaded track, the model
# loading once per batch, which is what makes queueing several requests cheap.
#
# STATE IS THE DIRECTORY, and there is no other record:
#
#   absent          never asked for
#   empty           please make this
#   FAILED-*.txt    tried, did not work, the note says why — delete it to retry
#   twelve files    done
#
# Three dispositions, and which one applies is the whole safety model:
#
#   PUBLISHED  (mv -T into the request folder)  it worked. `mv -T` replaces an
#           EMPTY directory atomically and REFUSES a non-empty one, so Syncthing
#           never sees a half-filled folder and a failure note is never clobbered.
#   MARKED   (a file written into the folder)  a terminal outcome that was not
#           success. The folder stops being empty and so is never re-queued, and
#           the reason survives on disk and reaches every device — which the .txt
#           design could not do, where a missed notification lost the request.
#   UNTOUCHED                                   a request we understood perfectly
#           and REFUSED to act on because the environment turned unsafe (a symlink
#           planted at the destination mid-run, a model that no longer matches its
#           pin). Nothing was tried, so nothing is recorded: the folder is still
#           empty, and the next poll retries it verbatim. Under .txt this needed a
#           park to rejected/ and a move back by hand.
#
# Root FILES are ignored entirely, and the `.txt` request format is retired
# (2026-08-28, owner). Nothing sweeps them, nothing moves them, nothing reports
# them: a file at the root cannot spin a timer the way it hot-looped the old
# .path unit, so leaving it costs nothing — and it stays visible where it was
# dropped, which beats hiding it in a rejected/ folder nobody opens. `rejected/`
# is therefore no longer created; an existing one is inert.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/zpool/catallenya/liquidroom/scripts/liquidroom.lib.sh
source "${SELF_DIR}/liquidroom.lib.sh"

for _bin in jq curl flock docker timeout stat awk sed tr sha256sum; do
    command -v "$_bin" >/dev/null || die "missing required command: ${_bin}"
done
: "${SLSK_USER:?SLSK_USER not set (EnvironmentFile=/etc/liquidroom.env)}"
: "${SLSK_PASS:?SLSK_PASS not set (EnvironmentFile=/etc/liquidroom.env)}"

mkdir -p "$STATE_DIR" "$WORK_DIR" "$MODELS_DIR" "$LR_ROOT"

# Serialise, and this is what makes a 5-minute poll safe against a 45-minute job:
# a poll landing mid-run fails the lock instantly and exits 0, so four of every
# five polls during a batch cost nothing at all. One separation at a time is also
# the right CPU policy on this box.
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

mapfile -d '' -t CANDS < <(list_folder_requests0)
(( ${#CANDS[@]} )) || { log "no empty request folders"; exit 0; }

TRUNCATED=0
if (( ${#CANDS[@]} > MAX_PER_RUN )); then
    TRUNCATED=$(( ${#CANDS[@]} - MAX_PER_RUN ))
    log "CAP: ${#CANDS[@]} requested, taking ${MAX_PER_RUN}, deferring ${TRUNCATED} to the next run"
    CANDS=("${CANDS[@]:0:$MAX_PER_RUN}")
fi
log "draining ${#CANDS[@]} request folder(s)"

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

# CANDS holds ABSOLUTE paths to empty depth-2 directories. Each is a request.
#
# Two checks the .txt design needed are gone by construction rather than by
# deletion: a request cannot "already exist" (a non-empty folder is not a
# candidate), and it cannot be a file with content in it (it is a directory).
for src in "${CANDS[@]}"; do
    [[ -n "$src" ]] || continue
    track="${src##*/}"; adir="${src%/*}"; artist="${adir##*/}"

    # Directories vanish under us routinely here — the owner deletes a request on
    # the phone, or a previous slot's publish landed. Not an error.
    [[ -d "$src" ]] || continue

    # A symlinked ARTIST directory would put every later mkdir/mv outside the root.
    # The publish path re-checks this after separation because half an hour passes
    # in between; this is the queue-time half.
    if [[ -L "$adir" ]]; then
        log "  SKIP   ${artist}/${track} (artist directory is a symlink)"
        line Refused Track "${artist} - ${track}" "Reason: the artist folder was unsafe"
        continue
    fi

    if ! valid_segment_lr "$artist" || ! under_root "$src"; then
        log "  MARK   ${artist}/${track} (unsafe artist name)"
        write_failure_marker "$src" "the artist folder name is unsafe" || true
        line Refused Track "${artist} - ${track}" "Reason: the artist folder name is unsafe"
        continue
    fi

    # THE PORTABILITY LOOP-BREAKER. Without this a request called
    # "What Ever Happened?" publishes to "What Ever Happened_" and the original
    # stays empty, is still a request, and is re-queued every five minutes forever.
    # See portable_rename_request().
    if ! track="$(portable_rename_request "$adir" "$track")"; then
        write_failure_marker "$src" "a portable-named version already exists" || true
        line Refused Track "${artist} - ${track}" \
             "Reason: a portable-named version already exists"
        continue
    fi
    src="${adir}/${track}"

    if ! valid_segment_lr "$track" || ! under_root "$src"; then
        log "  MARK   ${artist}/${track} (unsafe track name)"
        write_failure_marker "$src" "the track folder name is unsafe" || true
        line Refused Track "${artist} - ${track}" "Reason: the track folder name is unsafe"
        continue
    fi

    # IS THIS A REQUEST, OR A RESULT STILL ARRIVING? Syncthing creates directories
    # from its index, so an empty folder whose index entry lists files is a transfer
    # in progress and must be left alone. Definitive, not a heuristic — and it fails
    # CLOSED, so an unreachable API skips rather than acts. See
    # syncthing_index_has_files(). Left for the next poll, not marked: nothing is
    # wrong with the request, this run simply cannot tell yet.
    if syncthing_index_has_files "liquidroom/${artist}/${track}"; then
        log "  DEFER  ${artist}/${track} (syncthing index lists files — still arriving)"
        continue
    fi

    # Re-read emptiness after the API round trip: the folder may have started
    # filling while we asked about it.
    if [[ -n "$(find "$src" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        log "  DEFER  ${artist}/${track} (no longer empty)"
        continue
    fi

    if [[ -n "${SEEN[${artist}/${track}]:-}" ]]; then
        log "  DUPE   ${artist}/${track} (already queued this run)"
        continue
    fi

    IDX=$((IDX+1)); SEEN["${artist}/${track}"]="$IDX"
    A_MARKER[IDX]="$src"; A_ARTIST[IDX]="$artist"; A_TRACK[IDX]="$track"
    mkdir -p "${BATCH_DIR}/t${IDX}/dl"
    printf '%s\t%s\t%s\n' "$IDX" "$artist" "$track" >> "${BATCH_DIR}/spec.tsv"
    log "  QUEUE  [${IDX}] ${artist} - ${track}"
done

# decide <idx> <verb> <noun> <name> [detail] — a queued track's outcome is now known.
#
# Under the .txt design this DELETED the marker file. A request folder cannot be
# deleted, because it IS the destination, so a terminal FAILURE writes a marker
# INTO it instead. That does two jobs at once: the folder stops being empty and so
# is never re-queued, and the reason survives on disk and syncs to every device —
# which the .txt design could not do at all, where a missed notification meant the
# request was simply gone.
#
# `Finished` writes nothing. The twelve files that just landed are the receipt, and
# a marker beside them would be a lie.
decide() {
    local i="$1" verb="$2"
    if [[ "$verb" != "Finished" ]]; then
        write_failure_marker "${A_MARKER[$i]}" "$(marker_reason "$verb")" || true
    fi
    line "$verb" "$3" "$4" "${5:-}"
}

# refuse <idx> <log-detail> <verb> <noun> <name> [detail] — a queued track we will NOT act on
# because the box became unsafe, not because the request failed. The request folder
# is LEFT UNTOUCHED: nothing was attempted, so it is still exactly as valid as when
# it was typed, and a planted symlink or a swapped checkpoint must not cost the
# owner their request as well. Being untouched means still empty, which means the
# next poll retries it — the folder design gets this for free where the .txt design
# needed a park.
refuse() {
    local i="$1"
    log "  REFUSE [${i}] $2"
    # Nothing to park and nothing to write. The request folder is still empty and
    # therefore still a request, so the next poll picks it up unchanged — which is
    # exactly what this function used to achieve by moving a marker to rejected/,
    # now achieved by leaving well alone. Deliberately NOT a marker: a marker means
    # "this was attempted and did not work", and nothing was attempted here.
    line "$3" "$4" "$5" "${6:-}"
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
    # The destination EXISTS by design now — it is the request folder, and it is
    # empty. So the check is no longer "did anything appear" but "did anything
    # appear WITH CONTENT IN IT", which is the case that was ever dangerous: a
    # result syncing in from a peer, or a second run that beat us here.
    #
    # A symlink is still refused outright. `mv -T` closes the residual TOCTOU: it
    # replaces an empty directory atomically and REFUSES a non-empty one, so a
    # folder that fills between this check and the move is a clean per-track
    # failure rather than a nested publish (dest/publish/...) — verified.
    if [[ -L "$dest" ]] || { [[ -e "$dest" ]] && [[ ! -d "$dest" ]]; } \
       || [[ -n "$(find "$dest" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        log "  FAIL   [${i}] publish: destination is occupied"
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
(( TRUNCATED > 0 )) && log "  ${TRUNCATED} deferred; the next poll will take them"

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
