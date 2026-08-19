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
          [[ "$artist" == "RACE" ]] && mkdir -p "${LR_ROOT:?}/${artist}/${track}"
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
          [[ "$artist" == "EVILPARENT" ]] && ln -sfn "${STATE_DIR}" "${LR_ROOT:?}/${artist}"
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
rootn()  { count_requests; }
countf() { find "$1" -maxdepth 1 -name "$2" -printf 'x' 2>/dev/null | wc -c; }
runs_of(){ grep -c "run .* $1" "$DOCKER_LOG" || true; }

# ------------------------------------------------------------- suite hygiene
echo "suite hygiene"
has "the suite sets the mute"  "$(cat "${BASH_SOURCE[0]}")" 'export NTFY_DISABLE=1'
is  "muted notify still exits 0" "$(notify t "" tag body; echo $?)" "0"

# ------------------------------------------------------------------- parsing
echo "parse_request"
parse_request "The Strokes - What Ever Happened?.txt"
is "artist"                     "$PARSED_ARTIST" "The Strokes"
is "track keeps the ?"          "$PARSED_TRACK" "What Ever Happened?"
parse_request "Daft Punk - One More Time - Live.TXT"
is "first ' - ' splits"         "$PARSED_ARTIST" "Daft Punk"
is "rest stays in the track"    "$PARSED_TRACK" "One More Time - Live"
parse_request "  Lamp  -  二人のいた風景 .txt"
is "halves are trimmed (artist)" "$PARSED_ARTIST" "Lamp"
is "halves are trimmed (track)"  "$PARSED_TRACK" "二人のいた風景"
for badname in "NoSeparator.txt" " - track.txt" "artist - .txt" "A-B.txt" ".txt"; do
    parse_request "$badname" && bad "refuses '${badname}'" accepted refused || ok "refuses '${badname}'"
done

# --------------------------------------------------------------- path safety
echo "valid_segment_lr"
for good in "The Strokes" "What Ever Happened?" "二人のいた風景" "R.E.M." \
            "I Don't Know Why... But I Do" "AC-DC" "mei ehara" "07 Ghost"; do
    valid_segment_lr "$good" && ok "accepts '${good}'" || bad "accepts '${good}'" reject ok
done
for evil in "" "." ".." ".hidden" "a/b" 'a\b' "../etc" "-rf" "-" "--output-dir"; do
    valid_segment_lr "$evil" && bad "rejects '${evil}'" ok reject || ok "rejects '${evil}'"
done
valid_segment_lr "$(printf 'a\rb')" && bad "rejects CR" ok reject || ok "rejects CR"
valid_segment_lr "$(printf 'a\tb')" && bad "rejects TAB" ok reject || ok "rejects TAB"
valid_segment_lr "$(printf 'ab\033[31m')" && bad "rejects ESC" ok reject || ok "rejects ESC"
long="$(printf 'a%.0s' {1..100})"
valid_segment_lr "$long"   && ok "accepts 100 bytes" || bad "accepts 100 bytes" reject ok
valid_segment_lr "${long}a" && bad "rejects 101 bytes" ok reject || ok "rejects 101 bytes"

# ------------------------------------------------- marker emptiness (content)
echo "marker_is_content — a marker is EMPTY, not merely small"
MK="${TMP}/mk"; mkdir -p "$MK"
mk_is() { is "$1" "$(marker_is_content "${MK}/$2" && echo content || echo marker)" "$3"; }
: > "${MK}/empty";                                mk_is "zero bytes is a marker"        empty  marker
printf '\n'                    > "${MK}/nl";      mk_is "a lone newline is a marker"    nl     marker
printf '\r\n \t\v\f'           > "${MK}/ws";      mk_is "whitespace only is a marker"   ws     marker
printf '\xEF\xBB\xBF'          > "${MK}/bom";     mk_is "a bare BOM is a marker"        bom    marker
printf '\n\xEF\xBB\xBF\n  \n'  > "${MK}/bomws";   mk_is "BOM plus whitespace"           bomws  marker
printf 'x'                     > "${MK}/one";     mk_is "one real byte is content"      one    content
printf '\xEF\xBB\xBFhello'     > "${MK}/bomtext"; mk_is "BOM plus text is content"      bomtext content
# The sharp one. $( ) DROPS NUL bytes, so a file of pure NULs read into a shell
# variable comes back as the empty string and would be consumed as a marker —
# then deleted. Counted through a pipe instead, precisely for this.
head -c 32 /dev/zero           > "${MK}/nuls";    mk_is "NUL bytes are content"         nuls   content
head -c 5000 /dev/zero         > "${MK}/big";     mk_is "over the read bound is content" big   content
# The read bound is an upper bound on what we READ, never a content test: a file
# under it made of whitespace is still a marker, one over it is content unread.
printf '%*s' 4000 ''           > "${MK}/wsbig";   mk_is "4000 spaces is still a marker" wsbig  marker

echo "under_root"
fresh
is "a normal destination is inside" "$(under_root "${LR_ROOT}/The Strokes/x" && echo in)" "in"
is "traversal is outside"           "$(under_root "${LR_ROOT}/../../etc" && echo in)" ""
is "an absolute path is outside"    "$(under_root "/etc/passwd" && echo in)" ""
is "LR_ROOT itself is not inside"   "$(under_root "${LR_ROOT}" && echo in)" ""

# ------------------------------------------------- happy path + batch layout
echo "happy path"
fresh
: > "${LR_ROOT}/The Strokes - What Ever Happened?.txt"
run_triage
is  "root drained"            "$(rootn)" "0"
is  "one download container"  "$(runs_of download)" "1"
is  "one process container"   "$(runs_of process)" "1"
dest="${LR_ROOT}/The Strokes/What Ever Happened?"
[[ -d "$dest" ]] && ok "published dir exists" || bad "published dir exists" missing dir
is  "original present"  "$(countf "$dest" '*.flac')" "1"
is  "six stems present" "$(countf "$dest" '*_(*)_BS-Roformer-SW.mp3')" "6"
is  "lead+rhythm present" "$(countf "$dest" '*_listra92.mp3')" "2"
is  "three mixes present" "$(countf "$dest" '*(-1 *).mp3')" "3"
# ONE base name for the whole set, and it is the REQUESTED title. The separator
# rewrites "?" to "_", which used to leave a folder holding two spellings of one
# track — cosmetically wrong, and combine.py parses a single base off the front
# of a stem set. The requested title wins because the owner typed it and the
# containing folder already uses it. Live-run finding, 2026-08-15.
is  "one base name across all 12 files" \
    "$(cd "$dest" && for f in *; do echo "${f%% - The Strokes*}"; done | sort -u | wc -l)" "1"
# [?] not ? — in a glob a bare ? matches ANY character, so the naive pattern
# passes even when every file carries the sanitised "_". Bracket it to compare
# the literal question mark.
is  "and it is the requested title, ? intact" \
    "$(countf "$dest" 'What Ever Happened[?] - The Strokes*')" "12"
is  "no sanitised leftovers" \
    "$(countf "$dest" 'What Ever Happened_*')" "0"
has "summary logged" "$(cat "${TMP}/out")" "DONE"
is  "work spool cleaned up" "$(find "$STATE_DIR/work" -mindepth 1 | wc -l)" "0"

# ------------------------------------------------------------------ batching
echo "batching — one container per stage for N tracks"
fresh
: > "${LR_ROOT}/Artist One - Song A.txt"
: > "${LR_ROOT}/Artist Two - Song B.txt"
: > "${LR_ROOT}/Artist Three - Song C.txt"
run_triage
is "root drained"                 "$(rootn)" "0"
is "still one download container" "$(runs_of download)" "1"
is "still one process container"  "$(runs_of process)" "1"
is "three dirs published" "$(find "$LR_ROOT" -mindepth 2 -maxdepth 2 -type d ! -path "${REJECTED_DIR}/*" | wc -l)" "3"

echo "batching — a mid-batch failure does not sink the others"
fresh
: > "${LR_ROOT}/Good One - Song A.txt"
: > "${LR_ROOT}/FAILSEP - Doomed.txt"
: > "${LR_ROOT}/Good Two - Song B.txt"
run_triage
is "root drained"          "$(rootn)" "0"
[[ -d "${LR_ROOT}/Good One/Song A" && -d "${LR_ROOT}/Good Two/Song B" ]] \
    && ok "good tracks published" || bad "good tracks published" missing present
[[ -e "${LR_ROOT}/FAILSEP/Doomed" ]] && bad "failed track not published" present absent || ok "failed track not published"
has "failure logged" "$(cat "${TMP}/out")" "2/6 stems produced"
is "failed slot kept for autopsy" "$(find "$STATE_DIR/work" -mindepth 2 -maxdepth 2 -type d -name 't*' | wc -l)" "1"

# ------------------------------------------- drain invariant, failure branches
echo "download ping — fires once when something downloaded"
fresh
: > "${LR_ROOT}/Good One - Song A.txt"
run_triage
has "interim ping sent"   "$(cat "${TMP}/out")" "notified download of 1"
is  "exactly one ping"    "$(grep -c 'notified download of' "${TMP}/out")" "1"

echo "download ping — suppressed when NOTHING downloaded (final summary is imminent)"
fresh
: > "${LR_ROOT}/FAILDL - Nothing Anywhere.txt"
run_triage
hasnt "no interim ping"   "$(cat "${TMP}/out")" "notified download of"

echo "drain — download failure"
fresh
: > "${LR_ROOT}/FAILDL - Nothing Anywhere.txt"
run_triage
is "root drained"        "$(rootn)" "0"
has "failure logged"     "$(cat "${TMP}/out")" "sockseek exit 1"
is "nothing published"   "$(find "$LR_ROOT" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | grep -vc rejected || true)" "0"

echo "drain — empty download"
fresh
: > "${LR_ROOT}/EMPTYDL - Ghost Track.txt"
run_triage
is "root drained"    "$(rootn)" "0"
has "detail logged"  "$(cat "${TMP}/out")" "no audio file downloaded"

echo "drain — a lying manifest (ok with no files) never publishes"
fresh
: > "${LR_ROOT}/LIARSEP - Empty Promise.txt"
run_triage
is "root drained"      "$(rootn)" "0"
[[ -e "${LR_ROOT}/LIARSEP/Empty Promise" ]] && bad "no publish from empty result" present absent || ok "no publish from empty result"
has "guard logged"     "$(cat "${TMP}/out")" "manifest ok but"

echo "drain — split failure degrades, never fails"
fresh
: > "${LR_ROOT}/FAILSPLIT - Half A Loaf.txt"
run_triage
is "root drained"          "$(rootn)" "0"
dest="${LR_ROOT}/FAILSPLIT/Half A Loaf"
[[ -d "$dest" ]] && ok "published without split" || bad "published without split" missing dir
is  "six stems present"   "$(countf "$dest" '*_BS-Roformer-SW.mp3')" "6"
is  "no lead/rhythm"      "$(countf "$dest" '*_listra92.mp3')" "0"
is  "basic mix only"      "$(countf "$dest" '*(-1 *).mp3')" "1"
has "degradation surfaced" "$(cat "${TMP}/out")" "split unavailable"

echo "drain — destination appears mid-run"
fresh
: > "${LR_ROOT}/RACE - Photo Finish.txt"
run_triage
is "root drained"       "$(rootn)" "0"
has "refused, not nested" "$(cat "${TMP}/out")" "destination appeared"
is "the synced dir untouched" "$(find "${LR_ROOT}/RACE/Photo Finish" -type f | wc -l)" "0"

echo "publish — a symlink inside the container result is refused (F1)"
fresh
: > "${LR_ROOT}/EVILLINK - Trojan Track.txt"
run_triage
is "root drained"        "$(rootn)" "0"
has "symlink refused"    "$(cat "${TMP}/out")" "symlink inside result"
[[ -e "${LR_ROOT}/EVILLINK/Trojan Track" ]] && bad "nothing published" present absent || ok "nothing published"

echo "publish — a symlinked result directory is refused (F1)"
fresh
: > "${LR_ROOT}/EVILDIR - Sneaky Album.txt"
run_triage
is "root drained"        "$(rootn)" "0"
has "symlinked dir refused" "$(cat "${TMP}/out")" "result dir is a symlink"
[[ -L "${LR_ROOT}/EVILDIR/Sneaky Album" ]] && bad "no symlink in the tree" present absent || ok "no symlink in the tree"

echo "publish — a parent symlink planted mid-run is refused (L2)"
fresh
: > "${LR_ROOT}/EVILPARENT - Sneaky Parent.txt"
run_triage
has "parent symlink refused" "$(cat "${TMP}/out")" "artist directory is a symlink"
is  "nothing written through the link" \
    "$(find "${STATE_DIR}/Sneaky Parent" -maxdepth 0 2>/dev/null | wc -l)" "0"
# The request was understood and never attempted, so the marker is PARKED, not
# consumed: the owner fixes the tree and moves it back rather than retyping it.
is  "marker parked, not deleted" "$(countf "$REJECTED_DIR" 'EVILPARENT - Sneaky Parent.txt')" "1"
# The planted symlink is itself a stray at the root — counted, and drained by
# the next fire exactly like any other symlink that appears there.
is  "only the planted link is left at root" "$(rootn)" "1"
run_triage
is  "next run parks the link too" "$(rootn)" "0"
[[ -L "${REJECTED_DIR}/EVILPARENT" ]] && ok "planted link parked as a link" \
    || bad "planted link parked as a link" gone link

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
: > "${LR_ROOT}/Good One - Song A.txt"
printf 'swapped pickle\n' > "${MODELS_DIR}/sw.ckpt"
run_triage
has "mismatch logged"      "$(cat "${TMP}/out")" "MODEL SHA256 MISMATCH"
is  "download ran"         "$(runs_of download)" "1"
is  "separation did NOT"   "$(runs_of process)" "0"
is  "marker parked, not consumed" "$(countf "$REJECTED_DIR" 'Good One - Song A.txt')" "1"
is  "root drained"         "$(rootn)" "0"
is  "nothing published"    "$(find "$LR_ROOT" -mindepth 2 -maxdepth 2 -type d ! -path "${REJECTED_DIR}/*" | wc -l)" "0"

# --------------------------------------------------- strays and non-requests
echo "strays are parked, never deleted"
fresh
: > "${LR_ROOT}/randomnote.txt"                 # no " - "
: > "${LR_ROOT}/photo.jpg"                      # wrong extension
head -c 5000 /dev/zero > "${LR_ROOT}/big - file.txt"   # real content, not a marker
ln -s /etc/passwd "${LR_ROOT}/evil - link.txt"  # symlink
# MAX_PER_RUN=4 explicitly: this case is about the PARKING branches, and the
# default cap (3, sized for ~31min-per-track separation) would defer the fourth
# and make the assertions read as a parking failure. The cap has its own test.
MAX_PER_RUN=4 run_triage
is "root drained"       "$(rootn)" "0"
is "no container ran"   "$(wc -l < "$DOCKER_LOG")" "0"
is "all four parked"    "$(find "$REJECTED_DIR" -mindepth 1 | wc -l)" "4"
[[ -L "${REJECTED_DIR}/evil - link.txt" ]] && ok "symlink parked as a link" || bad "symlink parked as a link" gone link
is "big file intact"    "$(stat -c %s "${REJECTED_DIR}/big - file.txt")" "5000"

echo "a note whose NAME reads like a request is still a note (L1)"
fresh
# 2 KB — comfortably under the old MARKER_MAX_BYTES size rule, which therefore
# called this a marker, acted on it, and DELETED it once the outcome was
# decided. Emptiness is the test now, so it parks with its bytes intact.
printf 'x%.0s' {1..2048} > "${LR_ROOT}/Milk - Bread.txt"
run_triage
is "root drained"      "$(rootn)" "0"
is "no container ran"  "$(wc -l < "$DOCKER_LOG")" "0"
is "parked, not consumed" "$(countf "$REJECTED_DIR" 'Milk - Bread.txt')" "1"
is "parked intact"     "$(stat -c %s "${REJECTED_DIR}/Milk - Bread.txt")" "2048"
hasnt "never queued"   "$(cat "${TMP}/out")" "QUEUE"

echo "a marker an editor touched is still a marker (L1)"
fresh
: > "${LR_ROOT}/Empty Artist - Track A.txt"                       # zero bytes
printf '\n'           > "${LR_ROOT}/Newline Artist - Track B.txt" # editor's trailing newline
printf '\xEF\xBB\xBF' > "${LR_ROOT}/Bom Artist - Track C.txt"     # Windows editor's BOM
MAX_PER_RUN=3 run_triage
is "root drained"      "$(rootn)" "0"
is "nothing parked"    "$(find "$REJECTED_DIR" -mindepth 1 | wc -l)" "0"
is "all three published" \
   "$(find "$LR_ROOT" -mindepth 2 -maxdepth 2 -type d ! -path "${REJECTED_DIR}/*" | wc -l)" "3"

echo "park never clobbers"
fresh
mkdir -p "$REJECTED_DIR"; : > "${REJECTED_DIR}/note.txt"
: > "${LR_ROOT}/note.txt"
run_triage
is "root drained"     "$(rootn)" "0"
is "both copies live" "$(find "$REJECTED_DIR" -name 'note*' | wc -l)" "2"

echo "unsafe names are parked or invisible"
fresh
# A leading-dot name (".. - dotdot.txt", ".hidden - track.txt") is INVISIBLE by
# design, not parked: the *.txt glob in the .path unit and the ! -name '.*' in
# the listing both skip dotfiles, so it can neither be processed nor hot-loop.
: > "${LR_ROOT}/.. - dotdot.txt"
: > "${LR_ROOT}/evil"$'\n'"line - x.txt"  # newline in the name: must survive listing, then park
run_triage
is "root drained"   "$(rootn)" "0"   # dotfile stays on disk, invisible to count/glob/pipeline alike
[[ -f "${LR_ROOT}/.. - dotdot.txt" ]] && ok "dot-name ignored, untouched" || bad "dot-name ignored, untouched" gone present
is "dot-name not processed"  "$(find "$REJECTED_DIR" -name '*dotdot*' -printf 'x' | wc -c)" "0"
is "newline name parked" "$(find "$REJECTED_DIR" -name 'evil*' -printf 'x' | wc -c)" "1"
is "no container ran" "$(wc -l < "$DOCKER_LOG")" "0"

# ------------------------------------------------------------- state machine
echo "skip-if-exists"
fresh
mkdir -p "${LR_ROOT}/The Strokes/What Ever Happened?"
: > "${LR_ROOT}/The Strokes - What Ever Happened?.txt"
run_triage
is "root drained"      "$(rootn)" "0"
is "no container ran"  "$(wc -l < "$DOCKER_LOG")" "0"
has "skip logged"      "$(cat "${TMP}/out")" "already exists"

echo "duplicate request in one batch"
fresh
: > "${LR_ROOT}/Lamp - Smile Again.txt"
: > "${LR_ROOT}/Lamp - Smile Again .txt"    # same request after trim
run_triage
is "root drained"   "$(rootn)" "0"
has "dupe logged"   "$(cat "${TMP}/out")" "already queued this run"
is "published once" "$(find "${LR_ROOT}/Lamp" -mindepth 1 -maxdepth 1 -type d | wc -l)" "1"

echo "MAX_PER_RUN defers, second run finishes"
fresh
for i in 1 2 3; do : > "${LR_ROOT}/Artist ${i} - Track ${i}.txt"; done
MAX_PER_RUN=2 run_triage
is "two taken, one left"  "$(rootn)" "1"
has "deferral logged"     "$(cat "${TMP}/out")" "deferring 1"
MAX_PER_RUN=2 run_triage
is "second run drains it" "$(rootn)" "0"
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

echo "base_from_stem — recovers the separator's spelling so it can be undone"
bfs="$(python3 -c "import sys; sys.path.insert(0,'${LR_DIR}'); import process; \
print(process.base_from_stem('/x/What Ever Happened_ - The Strokes_(Vocals)_BS-Roformer-SW.mp3','Vocals'))")"
is "reads the sanitised base off a stem name" "$bfs" "What Ever Happened_ - The Strokes"
# The prefix swap that puts the requested title back. Same string surgery
# process.py does when publishing, asserted on the exact live-run filenames.
swap="$(python3 - <<'PY'
sep  = "What Ever Happened_ - The Strokes"
want = "What Ever Happened? - The Strokes"
for n in [f"{sep}_(Vocals)_BS-Roformer-SW.mp3", f"{sep}_(Guitar)_BS-Roformer-SW.mp3"]:
    print(want + n[len(sep):] if n.startswith(sep) else n)
PY
)"
has "vocals stem regains the ?"  "$swap" "What Ever Happened? - The Strokes_(Vocals)_BS-Roformer-SW.mp3"
has "guitar stem regains the ?"  "$swap" "What Ever Happened? - The Strokes_(Guitar)_BS-Roformer-SW.mp3"
hasnt "nothing sanitised survives" "$swap" "Happened_ -"

echo "find_stem anchoring — a stem token in the track name cannot mis-bind (F6)"
adv="$(python3 -c "import sys; sys.path.insert(0,'${LR_DIR}'); import process; \
print(process.find_stem(['Song_(Drums)_x - A_(Drums)_BS-Roformer-SW.mp3','Song_(Drums)_x - A_(Vocals)_BS-Roformer-SW.mp3'],'Vocals'))")"
is "Vocals binds to the vocals file, not the (Drums)-in-title one" \
   "$adv" "Song_(Drums)_x - A_(Vocals)_BS-Roformer-SW.mp3"

# --------------------------------------------------------------------- done
echo
echo "passed ${PASS}, failed ${FAIL}"
(( FAIL == 0 )) || exit 1
exit 0
