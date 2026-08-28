#!/usr/bin/env bash
# Regression tests for the liquidroom pipeline. Offline and free: no network,
# no ntfy, no real docker — the container boundary is a PATH-stubbed fake
# `docker` (the same seam philosophy as ai/tests/sink.py), with failure modes
# keyed on magic artist names (FAILDL, EMPTYDL, FAILSEP, LIARSEP, FAILSPLIT,
# RACE).
#
# TWO CLASSES OF CASE DOMINATE, same as the documents suite:
#
#   Path safety. Request names are owner-authored filenames synced in from any
#   device — valid_segment_lr() and under_root() are what stop one from
#   becoming a path, so they are tested against traversal, control bytes and
#   length rather than trusted. Unlike documents, Japanese and punctuation are
#   ACCEPTS here: the existing library is full of them.
#
#   The drain invariant. The .path unit re-fires while any *.txt remains, so a
#   branch that exits without moving its file spins systemd. Every failure
#   branch is asserted to drain — parked to rejected/ when the file was not
#   understood, deleted when its outcome was decided.
#
#   bash liquidroom/tests/run.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "${SELF_DIR}/../scripts" && pwd)"
LR_DIR="$(cd "${SELF_DIR}/.." && pwd)"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     expected: %s\n     actual:   %s\n' "$1" "$3" "$2"; }
is()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$2" "$3"; }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "$2" "contains $3"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "$2" "must not contain $3"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Scratch tree seams — nothing here can touch the real synced folder...
export LR_ROOT="${TMP}/root" STATE_DIR="${TMP}/state"
# ...and nothing here can reach the real PHONE either. The suite runs the REAL
# triage, and the documents suite's history shows exactly what happens without
# this line: dozens of live pings per full run.
export NTFY_DISABLE=1
export SKIP_SYNCTHING_GATE=1
export SLSK_USER=testuser SLSK_PASS=testpass
export COMPOSE_FILE=/dev/null
export DOCKER_LOG="${TMP}/docker.log"
# Model pins, scratch edition. The real pins name two ~350-700 MB checkpoints
# that no scratch tree can hold, so the suite substitutes its own table over
# tiny files — which means every case below still runs the REAL verify_models()
# against a satisfied pin, rather than the check being switched off for tests
# and therefore never exercised. TEST_MODEL_SHA is the sha256 of TEST_MODEL.
TEST_MODEL="liquidroom test model"
TEST_MODEL_SHA="2cf50259505ff060411399d7cf979e5aa0ea42cab456de755dbc77f8394ace20"
export MODEL_PINS="sw.ckpt ${TEST_MODEL_SHA} required
split.ckpt ${TEST_MODEL_SHA} optional"

# shellcheck source=../scripts/liquidroom.lib.sh
source "${SCRIPT_DIR}/liquidroom.lib.sh"

# ----------------------------------------------------------- the fake docker
# Stands in for BOTH container stages. Reads the same spec.tsv the real
# entrypoint reads, writes the same manifest.tsv and publish/ layout the real
# process.py writes — the host triage cannot tell the difference, which is the
# point: every host-side branch is reachable offline.
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
set -u
[[ "${1:-}" == "rm" ]] && exit 1   # no stale container in tests
args=("$@"); n=${#args[@]}
service="${args[n-3]}"; verb="${args[n-2]}"; batch="${args[n-1]}"
printf 'run %s %s\n' "$service" "$verb" >> "${DOCKER_LOG:?}"
BD="${STATE_DIR:?}/work/${batch}"
mf() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "${BD}/manifest.tsv"; }
dl_ok() { awk -F'\t' -v i="$1" '$1==i && $2=="dl" {st=$3} END{exit st!="ok"}' "${BD}/manifest.tsv" 2>/dev/null; }
case "$verb" in
  download)
    while IFS=$'\t' read -r idx artist track; do
      [[ -n "$idx" ]] || continue
      case "$artist" in
        FAILDL)  mf "$idx" dl fail "sockseek exit 1" ;;
        EMPTYDL) mf "$idx" dl fail "no audio file downloaded" ;;
        *) mkdir -p "${BD}/t${idx}/dl"
           : > "${BD}/t${idx}/dl/${track} - ${artist}.flac"
           mf "$idx" dl ok "${track} - ${artist}.flac" ;;
      esac
    done < "${BD}/spec.tsv" ;;
  process)
    while IFS=$'\t' read -r idx artist track; do
      [[ -n "$idx" ]] || continue
      dl_ok "$idx" || continue
      base="${track} - ${artist}"
      case "$artist" in
        FAILSEP) mf "$idx" proc fail "2/6 stems produced" ;;
        LIARSEP) mf "$idx" proc ok "" ;;   # says ok, delivers nothing
        *)
          pub="${BD}/t${idx}/publish"; mkdir -p "$pub"
          # process.py renames the separator's sanitised outputs back to the
          # REQUESTED title before publishing, so publish/ carries one spelling.
          # The stub models that end state; the rename itself is unit-tested
          # against the real functions further down.
          for s in Vocals Drums Bass Guitar Piano Other; do
            : > "${pub}/${base}_(${s})_BS-Roformer-SW.mp3"
          done
          : > "${pub}/${base}.flac"
          : > "${pub}/${base} (-1 Guitar).mp3"
          if [[ "$artist" == "FAILSPLIT" ]]; then
            mf "$idx" proc ok_no_split "split unavailable"
          else
            : > "${pub}/${base}_(Lead Guitar)_listra92.mp3"
            : > "${pub}/${base}_(Rhythm Guitar)_listra92.mp3"
            : > "${pub}/${base} (-1 Lead Guitar).mp3"
            : > "${pub}/${base} (-1 Rhythm Guitar).mp3"
            mf "$idx" proc ok ""
          fi
          # RACE: the destination appears (synced from "another device") while
          # the batch is still processing — the host must refuse the publish.
          # The request folder already exists — it IS the destination — so a bare
          # mkdir would be a no-op and prove nothing. What must be refused is a
          # destination with CONTENT in it, which is what a peer's copy looks like.
          if [[ "$artist" == "RACE" ]]; then
            mkdir -p "${LR_ROOT:?}/${artist}/${track}"
            : > "${LR_ROOT:?}/${artist}/${track}/synced-from-peer.mp3"
          fi
          # EVILLINK: a compromised container plants a symlink inside publish/
          # (e.g. exfiltrating a host secret) — the host must refuse to carry it
          # into the synced tree.
          [[ "$artist" == "EVILLINK" ]] && ln -sf /etc/hostname "${pub}/steal.txt"
          # EVILDIR: the whole publish/ is a symlink to a host dir — mv would
          # rename the LINK into the tree.
          if [[ "$artist" == "EVILDIR" ]]; then rm -rf "$pub"; ln -sf /etc "$pub"; fi
          # EVILPARENT: a PEER syncs "<artist> -> elsewhere" into the root while
          # this stage is running — the half hour between the queue-time path
          # checks and the publish. mkdir -p would follow it without complaint.
          # rm -rf first: the artist directory EXISTS now (it holds the request),
          # and `ln -s` against an existing directory would drop the link INSIDE it
          # rather than replacing it — which is not the attack being modelled.
          if [[ "$artist" == "EVILPARENT" ]]; then
            rm -rf "${LR_ROOT:?}/${artist}"
            ln -sfn "${STATE_DIR}" "${LR_ROOT:?}/${artist}"
          fi
          ;;
      esac
    done < "${BD}/spec.tsv" ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin/docker"

# ---------------------------------------------------------- the fake sockseek
# entrypoint.sh's download verb is the one in-container shell that handles
# PEER-CONTROLLED filenames, so it is driven directly (LR_WORK seam) with this
# stub standing in for the Soulseek client. Each case is keyed on the query and
# shapes the output directory it needs.
cat > "${TMP}/bin/sockseek" <<'SS'
#!/usr/bin/env bash
set -u
q="${1:-}"; out=""
while (( $# )); do [[ "$1" == "--output-dir" ]] && out="${2:-}"; shift; done
case "$q" in
  *"Newline Track"*)
    # A peer's filename with a newline IN it, and a smaller decoy that a
    # line-split selection would pick instead.
    head -c 200 /dev/zero > "${out}/$(printf 'weird\nname').flac"
    head -c 50  /dev/zero > "${out}/decoy.mp3"
    head -c 10  /dev/zero > "${out}/cover.jpg" ;;
  *"Mvfail Track"*)
    # A directory already sitting on the staging name forces the FIRST rename
    # to fail — the shape that used to fall through to the cleanup delete.
    head -c 200 /dev/zero > "${out}/song.flac"
    mkdir -p "${out}/.keep.flac" ;;
  *"Stdin Track"*)
    # A future sockseek that reads stdin. Without </dev/null this drains the
    # rest of spec.tsv and every later track vanishes with no error at all.
    # One level up: the download dir is swept clean by the entrypoint, and this
    # capture has to outlive the sweep to be assertable.
    cat > "${out}/../what-stdin-held.txt"
    head -c 200 /dev/zero > "${out}/song.flac" ;;
esac
exit 0
SS
chmod +x "${TMP}/bin/sockseek"
export PATH="${TMP}/bin:${PATH}"

fresh() {
    rm -rf "$LR_ROOT" "$STATE_DIR"; mkdir -p "$LR_ROOT" "$STATE_DIR" "$MODELS_DIR"
    # Both pinned models present and matching — the state a healthy box is in.
    printf '%s\n' "$TEST_MODEL" > "${MODELS_DIR}/sw.ckpt"
    printf '%s\n' "$TEST_MODEL" > "${MODELS_DIR}/split.ckpt"
    : > "$DOCKER_LOG"
}
run_triage() { bash "${SCRIPT_DIR}/liquidroom.triage.sh" >"${TMP}/out" 2>&1; }
# req <artist> <track> — make a request the way the owner does: an EMPTY DIRECTORY
# at <Artist>/<Track>/, which is also exactly where its result will land. Replaced
# `: > "$LR_ROOT/Artist - Track.txt"` throughout on 2026-08-28.
req() { mkdir -p "${LR_ROOT}/${1}/${2}"; }
# unpublished <artist> <track> — the request folder survives but holds no stems.
# Under .txt "not published" meant the destination was ABSENT; the folder IS the
# request now, so absence would mean something destroyed it. What must be true is
# that nothing was published INTO it.
unpublished() {
    local d="${LR_ROOT}/${1}/${2}"
    [[ -d "$d" ]] && (( $(countf "$d" '*.mp3') == 0 ))
}
# marked <artist> <track> — the request carries a failure note, so the next poll
# will not re-queue it, and the reason is on disk for every device to see.
marked() { compgen -G "${LR_ROOT}/${1}/${2}/FAILED - *.txt" >/dev/null; }

# Empty request folders still waiting. The old rootn() counted files at the root;
# root files are strays now, so both counts matter and they mean different things.
pending() { list_folder_requests0 | tr -cd '\0' | wc -c; }
countf() { find "$1" -maxdepth 1 -name "$2" -printf 'x' 2>/dev/null | wc -c; }
runs_of(){ grep -c "run .* $1" "$DOCKER_LOG" || true; }

# ------------------------------------------------------------- suite hygiene
echo "suite hygiene"
has "the suite sets the mute"  "$(cat "${BASH_SOURCE[0]}")" 'export NTFY_DISABLE=1'
is  "muted notify still exits 0" "$(notify t "" tag body; echo $?)" "0"

is "a normal destination is inside" "$(under_root "${LR_ROOT}/The Strokes/x" && echo in)" "in"
is "traversal is outside"           "$(under_root "${LR_ROOT}/../../etc" && echo in)" ""
is "an absolute path is outside"    "$(under_root "/etc/passwd" && echo in)" ""
is "LR_ROOT itself is not inside"   "$(under_root "${LR_ROOT}" && echo in)" ""

# ------------------------------------------------- the Syncthing quiet gate
# lr_quiet() became syncthing_quiet "$LR_ROOT" on 2026-08-19: the gate is one copy
# in syncthing/syncthing.lib.sh now, shared with pigeonhole, which watches a
# different directory inside the SAME Syncthing folder. The directory is the
# argument, and it has to be — the API answers for the whole "master" folder while
# the .tmp scan has to look where this run is about to write. A gate that scanned
# one fixed root would answer pigeonhole's question here, and quietly hand the
# separator a half-downloaded FLAC.
echo "syncthing gate"
fresh
declare -F syncthing_quiet >/dev/null && ok "syncthing_quiet defined" \
    || bad "syncthing_quiet defined" "missing" "a function"
is "a settled root is quiet"     "$(syncthing_quiet "$LR_ROOT" && echo quiet)" "quiet"
: > "${LR_ROOT}/.syncthing.Lamp - x.flac.tmp"
is "a scratch file means mid-transfer" "$(syncthing_quiet "$LR_ROOT" && echo quiet)" ""
mkdir -p "${LR_ROOT}/rejected"
is "and only for the directory it names" "$(syncthing_quiet "${LR_ROOT}/rejected" && echo quiet)" "quiet"
rm -f "${LR_ROOT}/.syncthing.Lamp - x.flac.tmp"
has "the triage names its own root" "$(cat "${SCRIPT_DIR}/liquidroom.triage.sh")" \
    'syncthing_quiet "$LR_ROOT"'
# Both pipelines wait on the same folder, so the wait budget is shared too — a
# second copy here would drift from the one the .path unit's start limit was
# sized against.
is "the wait budget comes from the shared lib" \
   "$(grep -c '^QUIET_\(WAIT_S\|POLL_S\)=' "${SCRIPT_DIR}/liquidroom.lib.sh")" "0"
is "and is defined once, there" \
   "$(grep -c '^QUIET_\(WAIT_S\|POLL_S\)=' /zpool/catallenya/syncthing/syncthing.lib.sh)" "2"

# ------------------------------------------------- happy path + batch layout
echo "happy path"
fresh
req "The Strokes" "What Ever Happened?"
run_triage
is  "one download container"  "$(runs_of download)" "1"
is  "one process container"   "$(runs_of process)" "1"
dest="${LR_ROOT}/The Strokes/What Ever Happened_"
[[ -d "$dest" ]] && ok "published dir exists" || bad "published dir exists" missing dir
is  "original present"  "$(countf "$dest" '*.flac')" "1"
is  "six stems present" "$(countf "$dest" '*_(*)_BS-Roformer-SW.mp3')" "6"
is  "lead+rhythm present" "$(countf "$dest" '*_listra92.mp3')" "2"
is  "three mixes present" "$(countf "$dest" '*(-1 *).mp3')" "3"
# ONE base name for the whole set, and it is the PORTABLE title. Two spellings
# of one track is cosmetically wrong and combine.py parses a single base off the
# front of a stem set, so folder and contents must agree — which they now do by
# construction, both deriving from the same sanitised globals. Live-run finding
# 2026-08-15; the spelling they agree ON changed 2026-08-21 (see
# portable_segment: the "?" strands the Windows peer).
is  "one base name across all 12 files" \
    "$(cd "$dest" && for f in *; do echo "${f%% - The Strokes*}"; done | sort -u | wc -l)" "1"
is  "and it is the portable title" \
    "$(countf "$dest" 'What Ever Happened_ - The Strokes*')" "12"
# [?] not ? — in a glob a bare ? matches ANY character, so the naive pattern
# passes even when no file carries a literal one. Bracket it to prove the
# reserved character reaches the synced tree nowhere.
is  "no reserved character reaches disk" \
    "$(countf "$dest" '*[?]*')" "0"
has "summary logged" "$(cat "${TMP}/out")" "DONE"
is  "work spool cleaned up" "$(find "$STATE_DIR/work" -mindepth 1 | wc -l)" "0"

# ------------------------------------------------------------------ batching
echo "batching — one container per stage for N tracks"
fresh
req "Artist One" "Song A"
req "Artist Two" "Song B"
req "Artist Three" "Song C"
run_triage
is "still one download container" "$(runs_of download)" "1"
is "still one process container"  "$(runs_of process)" "1"
is "three dirs published" "$(find "$LR_ROOT" -mindepth 2 -maxdepth 2 -type d ! -path "${REJECTED_DIR}/*" | wc -l)" "3"

echo "batching — a mid-batch failure does not sink the others"
fresh
req "Good One" "Song A"
req "FAILSEP" "Doomed"
req "Good Two" "Song B"
run_triage
[[ -d "${LR_ROOT}/Good One/Song A" && -d "${LR_ROOT}/Good Two/Song B" ]] \
    && ok "good tracks published" || bad "good tracks published" missing present
unpublished FAILSEP Doomed && ok "failed track not published" || bad "failed track not published" published unpublished
marked FAILSEP Doomed && ok "and it carries a failure note" || bad "and it carries a failure note" none note
has "failure logged" "$(cat "${TMP}/out")" "2/6 stems produced"
is "failed slot kept for autopsy" "$(find "$STATE_DIR/work" -mindepth 2 -maxdepth 2 -type d -name 't*' | wc -l)" "1"

# ------------------------------------------- drain invariant, failure branches
echo "download ping — fires once when something downloaded"
fresh
req "Good One" "Song A"
run_triage
has "interim ping sent"   "$(cat "${TMP}/out")" "notified download of 1"
is  "exactly one ping"    "$(grep -c 'notified download of' "${TMP}/out")" "1"

echo "download ping — suppressed when NOTHING downloaded (final summary is imminent)"
fresh
req "FAILDL" "Nothing Anywhere"
run_triage
hasnt "no interim ping"   "$(cat "${TMP}/out")" "notified download of"

echo "drain — download failure"
fresh
req "FAILDL" "Nothing Anywhere"
run_triage
has "failure logged"     "$(cat "${TMP}/out")" "sockseek exit 1"
unpublished FAILDL "Nothing Anywhere" && ok "nothing published" || bad "nothing published" published unpublished
marked FAILDL "Nothing Anywhere" && ok "the download failure is on disk" || bad "the download failure is on disk" none note

echo "drain — empty download"
fresh
req "EMPTYDL" "Ghost Track"
run_triage
has "detail logged"  "$(cat "${TMP}/out")" "no audio file downloaded"

echo "drain — a lying manifest (ok with no files) never publishes"
fresh
req "LIARSEP" "Empty Promise"
run_triage
unpublished LIARSEP "Empty Promise" && ok "no publish from empty result" || bad "no publish from empty result" published unpublished
has "guard logged"     "$(cat "${TMP}/out")" "manifest ok but"

echo "drain — split failure degrades, never fails"
fresh
req "FAILSPLIT" "Half A Loaf"
run_triage
dest="${LR_ROOT}/FAILSPLIT/Half A Loaf"
[[ -d "$dest" ]] && ok "published without split" || bad "published without split" missing dir
is  "six stems present"   "$(countf "$dest" '*_BS-Roformer-SW.mp3')" "6"
is  "no lead/rhythm"      "$(countf "$dest" '*_listra92.mp3')" "0"
is  "basic mix only"      "$(countf "$dest" '*(-1 *).mp3')" "1"
# The outcome now reads as an item and a detail — the track's name, then
# "Note: the lead/rhythm split was unavailable" — so the assertion follows the
# phrasing rather than a fragment that happened to survive both.
has "degradation surfaced" "$(cat "${TMP}/out")" "lead/rhythm split was unavailable"

echo "drain — destination appears mid-run"
fresh
req "RACE" "Photo Finish"
run_triage
has "refused, not nested" "$(cat "${TMP}/out")" "destination is occupied"
# The peer's file is the ONLY thing in there: nothing of ours was merged in
# beside it, and `mv -T` is what guarantees that rather than a check.
is "the peer copy is untouched" "$(find "${LR_ROOT}/RACE/Photo Finish" -type f | wc -l)" "1"

echo "publish — a symlink inside the container result is refused (F1)"
fresh
req "EVILLINK" "Trojan Track"
run_triage
has "symlink refused"    "$(cat "${TMP}/out")" "symlink inside result"
unpublished EVILLINK "Trojan Track" && ok "nothing published" || bad "nothing published" published unpublished

echo "publish — a symlinked result directory is refused (F1)"
fresh
req "EVILDIR" "Sneaky Album"
run_triage
has "symlinked dir refused" "$(cat "${TMP}/out")" "result dir is a symlink"
[[ -L "${LR_ROOT}/EVILDIR/Sneaky Album" ]] && bad "no symlink in the tree" present absent || ok "no symlink in the tree"

echo "publish — a parent symlink planted mid-run is refused (L2)"
fresh
req "EVILPARENT" "Sneaky Parent"
run_triage
has "parent symlink refused" "$(cat "${TMP}/out")" "artist directory is a symlink"
is  "nothing written through the link" \
    "$(find "${STATE_DIR}/Sneaky Parent" -maxdepth 0 2>/dev/null | wc -l)" "0"
# refuse() writes NOTHING. Under .txt the marker was parked so the owner could move
# it back; a request folder needs neither, because leaving it untouched already
# means "still empty, still a request, retried next poll". Here the hostile peer
# replaced the whole artist directory with a link, so there is no folder left to
# check — what matters is that nothing of ours was written through it.
hasnt "no failure note written through the link" \
      "$(find "${STATE_DIR}" -name 'FAILED - *' 2>/dev/null)" "FAILED"
# The planted symlink is simply left where it is. It cannot spin a timer, and
# find -type d never follows it, so it is invisible to the request finder.
[[ -L "${LR_ROOT}/EVILPARENT" ]] && ok "planted link left in place" \
    || bad "planted link left in place" gone link
is  "and it is not a request" "$(pending)" "0"

# --------------------------------------------------------------- model pins
echo "verify_models"
fresh
is "healthy tree verifies"      "$(verify_models && echo ok)" "ok"
rm -f "${MODELS_DIR}/split.ckpt"
is "a missing OPTIONAL model is fine" "$(verify_models && echo ok)" "ok"
printf 'tampered\n' > "${MODELS_DIR}/split.ckpt"
is "a MISMATCHED optional model is not" "$(verify_models 2>/dev/null && echo ok)" ""
fresh
printf 'tampered\n' > "${MODELS_DIR}/sw.ckpt"
is "a mismatched required model fails"  "$(verify_models 2>/dev/null && echo ok)" ""
fresh
rm -f "${MODELS_DIR}/sw.ckpt"
is "a missing required model fails"     "$(verify_models 2>/dev/null && echo ok)" ""
is "model_sha reads the table"          "$(model_sha sw.ckpt)" "$TEST_MODEL_SHA"
is "an unpinned name has no digest"     "$(model_sha nope.ckpt || true)" ""

echo "a tampered checkpoint holds the batch back, it does not run it (L5)"
fresh
req "Good One" "Song A"
printf 'swapped pickle\n' > "${MODELS_DIR}/sw.ckpt"
run_triage
has "mismatch logged"      "$(cat "${TMP}/out")" "MODEL SHA256 MISMATCH"
is  "download ran"         "$(runs_of download)" "1"
is  "separation did NOT"   "$(runs_of process)" "0"
# The request is UNTOUCHED, which is the folder-model equivalent of parking it:
# still empty means still a request, so the next poll retries it verbatim once the
# checkpoint is fixed. No note is written, because nothing was attempted.
is  "request still pending" "$(pending)" "1"
is  "nothing marked"        "$(countf "${LR_ROOT}/Good One/Song A" 'FAILED*')" "0"
unpublished "Good One" "Song A" && ok "nothing published" \
    || bad "nothing published" published unpublished

# --------------------------------------------------- strays and non-requests
echo "a folder holding a hidden file is not a request"
fresh
req "Empty Artist" "Track A"
req "Hidden Artist" "Track B"; : > "${LR_ROOT}/Hidden Artist/Track B/.DS_Store"
MAX_PER_RUN=3 run_triage
is "the empty one published" "$(countf "${LR_ROOT}/Empty Artist/Track A" '*.mp3')" "11"
is "the hidden-file one is untouched" \
   "$(find "${LR_ROOT}/Hidden Artist/Track B" -mindepth 1 | wc -l)" "1"
is "and only one container ran" "$(runs_of process)" "1"

echo "dotted names are invisible, root files are ignored"
fresh
# A dotted artist OR track folder is INVISIBLE by design, not marked: the
# ! -path '*/.*' pair in list_folder_requests0 skips both levels, so such a folder
# can neither be processed nor keep the poll busy. Marking one would be worse than
# ignoring it — the marker would be the only thing ever written into a directory
# the owner deliberately hid.
mkdir -p "${LR_ROOT}/.hidden artist/track"
mkdir -p "${LR_ROOT}/Real Artist/.hidden track"
# A root FILE is ignored outright as of 2026-08-28 — the .txt format is retired and
# nothing sweeps, moves or reports one. The newline in the name is kept because it
# is the shape that used to break the listing; now it must simply be left alone.
: > "${LR_ROOT}/evil"$'\n'"line - x.txt"
run_triage
is "no container ran" "$(wc -l < "$DOCKER_LOG")" "0"
[[ -d "${LR_ROOT}/.hidden artist/track" ]] && ok "dotted artist untouched" \
    || bad "dotted artist untouched" gone present
[[ -d "${LR_ROOT}/Real Artist/.hidden track" ]] && ok "dotted track untouched" \
    || bad "dotted track untouched" gone present
is "neither was marked"  "$(find "$LR_ROOT" -name 'FAILED*' | wc -l)" "0"
is "the root file is left where it was" \
   "$(find "$LR_ROOT" -maxdepth 1 -name 'evil*' -printf 'x' | wc -c)" "1"
is "nothing was moved to rejected/" "$(find "$REJECTED_DIR" -mindepth 1 2>/dev/null | wc -l)" "0"
is "and it is not a request"        "$(pending)" "0"

# ------------------------------------------------------------- state machine
echo "skip-if-exists"
fresh
# "Already done" is now "the folder has something in it", so the existing result
# must be POPULATED — an empty folder of that name would be a second request, not
# a finished track. The new request still carries the "?" the owner typed, and the
# portable rename has to see through it to the name actually on disk.
mkdir -p "${LR_ROOT}/The Strokes/What Ever Happened_"
: > "${LR_ROOT}/The Strokes/What Ever Happened_/existing.mp3"
req "The Strokes" "What Ever Happened?"
run_triage
is "no container ran"  "$(wc -l < "$DOCKER_LOG")" "0"
has "collision logged" "$(cat "${TMP}/out")" "already exists"
is  "the finished track is untouched" \
    "$(find "${LR_ROOT}/The Strokes/What Ever Happened_" -mindepth 1 | wc -l)" "1"

echo "duplicate request in one batch"
fresh
req "Lamp" "Smile Again"
req "Lamp" "Smile Again "    # same request after trim
run_triage
# Two DIRECTORIES cannot share a name, so the .txt "same request twice" case
# arrives differently: the trailing space is trimmed by portable_rename_request,
# the rename collides with the folder already there, and the loser is marked. That
# trim is load-bearing — Windows strips a trailing space, so both names are one
# folder on a peer.
has "collision logged"  "$(cat "${TMP}/out")" "already exists"
is  "published once"    "$(countf "${LR_ROOT}/Lamp/Smile Again" '*.mp3')" "11"
is  "the loser was not published" \
    "$(countf "${LR_ROOT}/Lamp/Smile Again " '*.mp3')" "0"
marked Lamp "Smile Again " && ok "the loser carries a note" \
    || bad "the loser carries a note" none note

echo "MAX_PER_RUN defers, second run finishes"
fresh
for i in 1 2 3; do req "Artist ${i}" "Track ${i}"; done
MAX_PER_RUN=2 run_triage
# pending(), not rootn(): work waiting is an EMPTY REQUEST FOLDER now, and root
# files are strays that have nothing to do with the cap.
is "two taken, one left"  "$(pending)" "1"
has "deferral logged"     "$(cat "${TMP}/out")" "deferring 1"
MAX_PER_RUN=2 run_triage
is "second run drains it" "$(pending)" "0"
is "all three published"  "$(find "$LR_ROOT" -mindepth 2 -maxdepth 2 -type d ! -path "${REJECTED_DIR}/*" | wc -l)" "3"

echo "stale work dirs are purged"
fresh
mkdir -p "${STATE_DIR}/work/oldbatch"
touch -d "10 days ago" "${STATE_DIR}/work/oldbatch"
run_triage   # empty root: exits after housekeeping
is "old batch dir purged" "$(find "$STATE_DIR/work" -mindepth 1 -maxdepth 1 | wc -l)" "0"

# ------------------------------------------------- entrypoint download stage
# Runs the REAL in-container script on the host against a scratch /work, with
# the fake sockseek on PATH. Everything here is peer-controlled input reaching
# shell, which is why it is exercised rather than reasoned about.
echo "entrypoint download — peer filenames and checked renames (L3)"
ep_mf() { awk -F'\t' -v i="$1" -v c="$2" '$1==i && $2=="dl" {v=$c} END{print v}' "${EPB}/manifest.tsv"; }
ep_run() {
    EPB="${STATE_DIR}/work/$1"
    env LR_WORK="${STATE_DIR}/work" HOME="${TMP}/home" \
        bash "${LR_DIR}/entrypoint.sh" download "$1" >"${TMP}/ep.out" 2>&1
}

fresh
mkdir -p "${STATE_DIR}/work/nlbatch"
printf '1\tNewline Artist\tNewline Track\n' > "${STATE_DIR}/work/nlbatch/spec.tsv"
ep_run nlbatch
is "status ok"        "$(ep_mf 1 3)" "ok"
is "detail is the requested title" "$(ep_mf 1 4)" "Newline Track - Newline Artist.flac"
# The 200-byte newline-named file, not the 50-byte decoy a line-split pipeline
# would have picked after truncating the real name at its newline.
is "the LARGEST audio file survived, renamed" \
   "$(stat -c %s "${STATE_DIR}/work/nlbatch/t1/dl/Newline Track - Newline Artist.flac" 2>/dev/null)" "200"
is "exactly one file left in dl" \
   "$(find "${STATE_DIR}/work/nlbatch/t1/dl" -type f | wc -l)" "1"

fresh
mkdir -p "${STATE_DIR}/work/mvbatch"
printf '1\tMvfail Artist\tMvfail Track\n' > "${STATE_DIR}/work/mvbatch/spec.tsv"
ep_run mvbatch
is "a failed rename is reported as a failure" "$(ep_mf 1 3)" "fail"
has "and says which rename"  "$(ep_mf 1 4)" "could not stage"
# The whole point: the cleanup delete must never run behind a failed rename.
is "the real download still exists" \
   "$(stat -c %s "${STATE_DIR}/work/mvbatch/t1/dl/song.flac" 2>/dev/null)" "200"

fresh
mkdir -p "${STATE_DIR}/work/sibatch"
printf '1\tStdin Artist\tStdin Track\n2\tSecond Artist\tSecond Track\n' \
    > "${STATE_DIR}/work/sibatch/spec.tsv"
ep_run sibatch
is "the client read nothing from the spec" \
   "$(stat -c %s "${STATE_DIR}/work/sibatch/t1/what-stdin-held.txt" 2>/dev/null)" "0"
is "track 1 still completed"  "$(ep_mf 1 3)" "ok"
# Track 2 only exists in the manifest at all if the loop's stdin survived the
# client. Its own outcome is a failure (the stub plants nothing for it) — what
# is asserted is that it was REACHED.
is "track 2 was still reached" "$(ep_mf 2 3)" "fail"
is "both slots reached the manifest" \
   "$(awk -F'\t' '$2=="dl"' "${STATE_DIR}/work/sibatch/manifest.tsv" | wc -l)" "2"

# ------------------------------------------------------------ mix arithmetic
echo "mix arithmetic (process.py --plan-mixes)"
MIXD="${TMP}/mix"; mkdir -p "$MIXD"
for s in Vocals Drums Bass Guitar Piano Other; do : > "${MIXD}/x_(${s})_BS-Roformer-SW.mp3"; done
: > "${MIXD}/x_(Lead Guitar)_listra92.mp3"
: > "${MIXD}/x_(Rhythm Guitar)_listra92.mp3"
plans="$(python3 "${LR_DIR}/process.py" --plan-mixes "$MIXD")"
is  "three mixes planned"     "$(wc -l <<<"$plans")" "3"
is  "-1 Guitar sums 5 stems"  "$(awk -F'\t' '$1=="track (-1 Guitar).mp3"{print $2}' <<<"$plans")" "5"
is  "-1 Lead sums 6"          "$(awk -F'\t' '$1=="track (-1 Lead Guitar).mp3"{print $2}' <<<"$plans")" "6"
is  "-1 Rhythm sums 6"        "$(awk -F'\t' '$1=="track (-1 Rhythm Guitar).mp3"{print $2}' <<<"$plans")" "6"
g="$(awk -F'\t' '$1=="track (-1 Guitar).mp3"' <<<"$plans")"
hasnt "-1 Guitar excludes the guitar stem" "$g" "_(Guitar)_"
l="$(awk -F'\t' '$1=="track (-1 Lead Guitar).mp3"' <<<"$plans")"
has   "-1 Lead keeps rhythm"   "$l" "Rhythm Guitar"
hasnt "-1 Lead drops lead"     "$l" "(Lead Guitar)"
r="$(awk -F'\t' '$1=="track (-1 Rhythm Guitar).mp3"' <<<"$plans")"
has   "-1 Rhythm keeps lead"   "$r" "(Lead Guitar)"
hasnt "-1 Rhythm drops rhythm" "$r" "(Rhythm Guitar)"

MIXD2="${TMP}/mix2"; mkdir -p "$MIXD2"
for s in Vocals Drums Bass Guitar Piano Other; do : > "${MIXD2}/x_(${s})_BS-Roformer-SW.mp3"; done
plans2="$(python3 "${LR_DIR}/process.py" --plan-mixes "$MIXD2")"
is "no split -> basic mix only" "$(wc -l <<<"$plans2")" "1"

# base_from_stem + the prefix swap survive portable_segment, and are no longer
# about "?" specifically. The requested base is now already the portable one, so
# the separator agrees with us on the reserved characters — but its sanitising
# is its own business and not something this repo controls, so the repair stays
# as the general defence against ANY spelling it invents. It is a no-op when the
# two agree. The synthetic "?" below is kept because it is the one mangling this
# box has actually observed.
echo "base_from_stem — recovers the separator's spelling so it can be undone"
bfs="$(python3 -c "import sys; sys.path.insert(0,'${LR_DIR}'); import process; \
print(process.base_from_stem('/x/What Ever Happened_ - The Strokes_(vocals)_BS-Roformer-SW.mp3','Vocals'))")"
is "reads the sanitised base off a stem name" "$bfs" "What Ever Happened_ - The Strokes"
# The prefix swap that puts the requested title back, then the case
# normalisation — the same two-step surgery process.py does when publishing,
# asserted on the exact live-run filenames. The INPUT is lowercase on purpose:
# BS-Roformer-SW.yaml declares its instruments lowercase, so that is what
# audio-separator actually writes. This suite fabricated Title Case here for a
# year and passed only because every matcher is IGNORECASE, which meant the
# spelling production really emits was never once exercised.
swap="$(python3 - <<PY
import sys; sys.path.insert(0, '${LR_DIR}'); import process
sep  = "What Ever Happened_ - The Strokes"
want = "What Ever Happened? - The Strokes"
for n, s in [(f"{sep}_(vocals)_BS-Roformer-SW.mp3", "Vocals"),
             (f"{sep}_(guitar)_BS-Roformer-SW.mp3", "Guitar")]:
    n = want + n[len(sep):] if n.startswith(sep) else n
    print(process.canon_stem_name(n, s))
PY
)"
has "vocals stem takes our base"  "$swap" "What Ever Happened? - The Strokes_(Vocals)_BS-Roformer-SW.mp3"
has "guitar stem takes our base"  "$swap" "What Ever Happened? - The Strokes_(Guitar)_BS-Roformer-SW.mp3"
hasnt "the separator's spelling survives" "$swap" "Happened_ -"
hasnt "the separator's lowercase survives" "$swap" "_(vocals)_"

echo "find_stem anchoring — a stem token in the track name cannot mis-bind (F6)"
adv="$(python3 -c "import sys; sys.path.insert(0,'${LR_DIR}'); import process; \
print(process.find_stem(['Song_(Drums)_x - A_(Drums)_BS-Roformer-SW.mp3','Song_(Drums)_x - A_(Vocals)_BS-Roformer-SW.mp3'],'Vocals'))")"
is "Vocals binds to the vocals file, not the (Drums)-in-title one" \
   "$adv" "Song_(Drums)_x - A_(Vocals)_BS-Roformer-SW.mp3"

echo "canon_stem_name — published casing is canonical, and anchored like find_stem"
canon="$(python3 - <<PY
import sys; sys.path.insert(0, '${LR_DIR}'); import process
print(process.canon_stem_name("A - B_(piano)_BS-Roformer-SW.mp3", "Piano"))
print(process.canon_stem_name("Song_(vocals)_x - A_(vocals)_BS-Roformer-SW.mp3", "Vocals"))
print(process.canon_stem_name("A - B_(Lead Guitar)_listra92.mp3", "Lead Guitar"))
PY
)"
has "the separator's lowercase token is canonicalised" "$canon" \
    "A - B_(Piano)_BS-Roformer-SW.mp3"
has "a stem token inside the TITLE is left alone"      "$canon" \
    "Song_(vocals)_x - A_(Vocals)_BS-Roformer-SW.mp3"
has "an already-canonical name is a no-op"             "$canon" \
    "A - B_(Lead Guitar)_listra92.mp3"

# ------------------------------------------------------- the folder state machine
# The four states a track folder can be in, and the two gestures that move between
# them. This is the whole user-facing contract, so it is asserted directly rather
# than inferred from the pipeline runs above.
echo "folder state machine"
fresh
req "State" "Empty"                                    # -> a request
mkdir -p "${LR_ROOT}/State/Marked"; : > "${LR_ROOT}/State/Marked/FAILED - no audio file was found.txt"
mkdir -p "${LR_ROOT}/State/Done";   : > "${LR_ROOT}/State/Done/x.mp3"
is "only the empty folder is a request" "$(pending)" "1"
has "and it is the right one" "$(list_folder_requests0 | tr '\0' '\n')" "State/Empty"

echo "deleting the note makes it a request again — the retry gesture"
rm -f "${LR_ROOT}/State/Marked/FAILED - no audio file was found.txt"
is "the marked folder is now pending too" "$(pending)" "2"

echo "an empty ARTIST folder is never a request"
fresh
mkdir -p "${LR_ROOT}/Lonely Artist"
is "nothing pending"  "$(pending)" "0"
run_triage
is "no container ran" "$(wc -l < "$DOCKER_LOG")" "0"
[[ -d "${LR_ROOT}/Lonely Artist" ]] && ok "and it is left alone" \
    || bad "and it is left alone" gone present

echo "rejected/ contents are never requests"
fresh
mkdir -p "${REJECTED_DIR}/Some Parked Thing"
is "nothing pending" "$(pending)" "0"

echo "a newline in a folder name survives listing"
fresh
mkdir -p "${LR_ROOT}/News"$'\n'"line/Track"
is "listed exactly once" "$(pending)" "1"

# ------------------------------------------------------------- failure markers
echo "marker_reason maps every terminal verb"
is "Dropped"     "$(marker_reason Dropped)"     "no audio file was found"
is "Halted"      "$(marker_reason Halted)"      "separation did not finish"
is "Refused"     "$(marker_reason Refused)"     "the destination was unsafe"
is "Emptied"     "$(marker_reason Emptied)"     "the separator produced nothing"
is "Unpublished" "$(marker_reason Unpublished)" "the result could not be moved into place"
is "Raced"       "$(marker_reason Raced)"       "the destination appeared mid-run"
is "an unmapped verb still names a file" "$(marker_reason Nonsense)" "it did not complete"
hasnt "no reason carries a slash" "$(for v in Dropped Halted Refused Emptied Unpublished Raced; do marker_reason "$v"; done)" "/"

echo "write_failure_marker"
fresh
mkdir -p "${LR_ROOT}/M/empty"
write_failure_marker "${LR_ROOT}/M/empty" "no audio file was found" && ok "writes into an empty folder" \
    || bad "writes into an empty folder" failed ok
is  "the folder is no longer a request" "$(pending)" "0"
has "the body names the reason" "$(cat "${LR_ROOT}/M/empty/FAILED - no audio file was found.txt")" "no audio file was found"
has "and says how to retry"     "$(cat "${LR_ROOT}/M/empty/FAILED - no audio file was found.txt")" "Delete this file to try again"
# A folder with content in it is a RESULT, not a request, and writing a failure
# note into someone else's twelve files would be vandalism dressed as a receipt.
mkdir -p "${LR_ROOT}/M/occupied"; : > "${LR_ROOT}/M/occupied/peer.mp3"
write_failure_marker "${LR_ROOT}/M/occupied" "no audio file was found"
is "a non-empty folder is left alone" "$(countf "${LR_ROOT}/M/occupied" 'FAILED*')" "0"

echo "mv -T cannot clobber a failure note (the publish guard)"
fresh
mkdir -p "${TMP}/src"; : > "${TMP}/src/stem.mp3"
mkdir -p "${LR_ROOT}/G/marked"; : > "${LR_ROOT}/G/marked/FAILED - no audio file was found.txt"
mv -T "${TMP}/src" "${LR_ROOT}/G/marked" 2>/dev/null \
    && bad "publish over a note is refused" allowed refused \
    || ok "publish over a note is refused"
# ...and it DOES replace an empty one, which is what makes publishing in place work
mkdir -p "${LR_ROOT}/G/empty"
mv -T "${TMP}/src" "${LR_ROOT}/G/empty" 2>/dev/null \
    && ok "publish into an empty folder works" \
    || bad "publish into an empty folder works" refused allowed

# --------------------------------------------------------- portable rename
echo "portable_rename_request"
fresh
mkdir -p "${LR_ROOT}/P/What Ever Happened?"
is "the reserved character is renamed away" \
   "$(portable_rename_request "${LR_ROOT}/P" "What Ever Happened?" 2>/dev/null)" "What Ever Happened_"
[[ -d "${LR_ROOT}/P/What Ever Happened_" ]] && ok "and the folder moved with it" \
    || bad "and the folder moved with it" missing present
# THE LOOP-BREAKER: request and destination must be the same path afterwards, or
# the original stays empty and is re-queued every poll forever.
[[ -e "${LR_ROOT}/P/What Ever Happened?" ]] && bad "no original left behind" present absent \
    || ok "no original left behind"
mkdir -p "${LR_ROOT}/P/Trailing Space "
is "trailing whitespace is trimmed" \
   "$(portable_rename_request "${LR_ROOT}/P" "Trailing Space " 2>/dev/null)" "Trailing Space"
mkdir -p "${LR_ROOT}/P/Clean Name"
is "a clean name is a no-op" \
   "$(portable_rename_request "${LR_ROOT}/P" "Clean Name" 2>/dev/null)" "Clean Name"
mkdir -p "${LR_ROOT}/P/Taken_" "${LR_ROOT}/P/Taken?"
portable_rename_request "${LR_ROOT}/P" "Taken?" >/dev/null 2>&1 \
    && bad "a taken portable name is refused" renamed refused \
    || ok "a taken portable name is refused"
[[ -d "${LR_ROOT}/P/Taken?" ]] && ok "and both folders survive" \
    || bad "and both folders survive" gone present

# ------------------------------------------------- the Syncthing index check
# The definitive answer to "request, or result still arriving?". Syncthing creates
# directories FROM its index, so an empty folder whose index entry lists files is a
# transfer in progress. Driven through a curl stub because the real API is not
# reachable from a scratch tree.
echo "syncthing index check"
fresh
cat > "${TMP}/bin/curl" <<'CURL'
#!/usr/bin/env bash
# Answers /rest/db/browse. ARRIVING is mid-transfer (index lists a file); anything
# else is genuinely empty. Every other curl call answers "[]" harmlessly.
for a in "$@"; do case "$a" in prefix=*ARRIVING*) echo '[{"name":"x.mp3"}]'; exit 0 ;; esac; done
echo '[]'
CURL
chmod +x "${TMP}/bin/curl"
is "an index that lists files means NOT a request" \
   "$(SKIP_SYNCTHING_GATE=0 syncthing_index_has_files 'liquidroom/ARRIVING/Track' && echo has)" "has"
is "an empty index means it IS a request" \
   "$(SKIP_SYNCTHING_GATE=0 syncthing_index_has_files 'liquidroom/Quiet/Track' && echo has)" ""
# Fails CLOSED: a broken API must skip the candidate, never queue it. A false skip
# costs one poll; a false queue costs a 45-minute job republishing what was there.
printf '#!/usr/bin/env bash\nexit 7\n' > "${TMP}/bin/curl"; chmod +x "${TMP}/bin/curl"
is "an unreachable API fails closed" \
   "$(SKIP_SYNCTHING_GATE=0 syncthing_index_has_files 'liquidroom/Any/Track' && echo has)" "has"
printf '#!/usr/bin/env bash\necho not json\n' > "${TMP}/bin/curl"; chmod +x "${TMP}/bin/curl"
is "malformed JSON fails closed" \
   "$(SKIP_SYNCTHING_GATE=0 syncthing_index_has_files 'liquidroom/Any/Track' && echo has)" "has"
rm -f "${TMP}/bin/curl"

# --------------------------------------------------------------------- done
echo
echo "passed ${PASS}, failed ${FAIL}"
(( FAIL == 0 )) || exit 1
exit 0
