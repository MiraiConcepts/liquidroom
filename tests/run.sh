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
          ;;
      esac
    done < "${BD}/spec.tsv" ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin/docker"
export PATH="${TMP}/bin:${PATH}"

fresh() { rm -rf "$LR_ROOT" "$STATE_DIR"; mkdir -p "$LR_ROOT" "$STATE_DIR"; : > "$DOCKER_LOG"; }
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
is  "original present"  "$(countf "$dest" 'What Ever Happened? - The Strokes.flac')" "1"
is  "six stems present" "$(countf "$dest" '*_(*)_BS-Roformer-SW.mp3')" "6"
is  "lead+rhythm present" "$(countf "$dest" '*_listra92.mp3')" "2"
is  "three mixes present" "$(countf "$dest" '*(-1 *).mp3')" "3"
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
