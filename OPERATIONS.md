# liquidroom — operations

Running, fixing and recovering the pipeline. What it is and why it is shaped this
way lives in [README.md](README.md).

## Commands

```bash
# FIRST INSTALL ONLY — create the drop folder. The triage makes it on its first
# run, but you cannot drop a request into a directory that does not exist yet,
# and the .path unit has nothing to watch until it does.
mkdir -p /zpool/catallenya/syncthing/data/master/liquidroom/rejected

bash liquidroom/tests/run.sh                    # offline suite (no docker, no ntfy)
# REBUILD AFTER EVERY EDIT TO process.py OR entrypoint.sh. Both are COPYied into
# the image, so an edit in this repo changes NOTHING about what runs until this
# command has been run — the tests pass, the diff looks applied, and the
# pipeline keeps executing the old code. Nothing warns you. (No watchtower here:
# locally built, so there is no upstream image to poll.)
docker compose --profile liquidroom build liquidroom-soulseek
# Confirm the running image really carries your change:
docker run --rm --entrypoint grep catallenya-liquidroom -c '<something-you-added>' /app/process.py
bash liquidroom/scripts/models.sh               # fetch/verify both models (~1 GB)
# Force a run now. --no-block is not optional in practice: without it systemctl
# WAITS for the oneshot to finish, so the terminal sits silent for the ~35 min a
# separation takes and reads exactly like a hang. Ctrl-C there only detaches the
# client — the job keeps running, and a second `start` is a no-op while it does.
sudo systemctl start --no-block liquidroom.triage.service
journalctl -u liquidroom.triage.service -f      # watch a run (Ctrl-C is safe)

# After a run of rapid failures, clear the service's failed state. The timer keeps
# firing regardless — it is a clock, not a watcher — so recovery is one command
# and the next poll picks the request up within five minutes:
sudo systemctl reset-failed liquidroom.triage.service
systemctl is-active liquidroom.triage.timer     # must print: active
#
# THIS BLOCK USED TO SAY SOMETHING ELSE, and the difference is worth knowing if
# you remember the old procedure. Under the .path unit that this timer replaced on
# 2026-08-28, reset-failed did NOT re-arm the watcher: it landed `inactive`,
# watched nothing, and still looked healthy to `is-failed`, so you had to follow
# it with an explicit `start` on the path unit. There is no watcher to re-arm now.
# The adhoc class's StartLimitIntervalSec=1800 / StartLimitBurst=12 went with it
# too — they bounded a .path unit that re-fires while its glob still matches, and
# liquidroom is Class=scheduled now, which sets no start limit at all.
sudo bash liquidroom/uninstall.sh               # zero-artifact teardown
```

## State and credentials

- Runtime state lives in `liquidroom/state/` (gitignored): `work/` per-batch
  spool — failed batches keep their dirs (and `download.log`/`process.log`)
  for 7 days as autopsies — and `models/` (two checkpoints and their two config
  YAMLs, sha256-pinned as `MODEL_PINS` in `scripts/liquidroom.lib.sh`).
  `scripts/models.sh` fetches and verifies them; the triage re-verifies before
  every separation run, so a swapped or corrupted cached checkpoint stops the
  batch instead of being loaded. A missing BS-Roformer-SW file is fatal; a
  missing listra92 pair is not — the lead/rhythm split already degrades to
  `ok_no_split`, and only a MISMATCH is fatal there.
- Credentials: `/etc/liquidroom.env` (root 0600) with `SLSK_USER`/`SLSK_PASS`.
  A **dedicated** Soulseek account — the server kicks the older session when a
  name logs in twice, so never reuse the desktop account. First login claims
  the name; ~30 days idle and it lapses.
- Sockseek is a pinned release binary inside the image. Its CLI surface was
  researched, not yet verified against a live run — before first use:
  `docker compose run --rm liquidroom-soulseek sockseek-help`, then fix
  `entrypoint.sh` if any flag or conf key is spelled differently.
- Router port-forward of TCP 50300 to this box is optional but makes downloads
  from passive peers reliable; without it Sockseek's candidate fallback
  usually recovers at the cost of a retry.
- The lead/rhythm split (`listra92`, community model, no published SDR) is
  **non-fatal**. Disabling it entirely is a one-line change in `process.py`
  (`split_guitar` call); switching the separation model is one line in the same
  file (`SEP_MODEL`).

## Why a run takes ~31 minutes — the full diagnosis

The headline number and the design decision behind it are in
[README.md](README.md). This is the working that rules out a fault.

The hardware is fine: raw FP32 GEMM measures **520 GFLOPS** (~60% of this chip's
theoretical peak), torch uses AVX-512 with MKL on all 6 physical cores, and the
container has no CPU quota. The cost is the model itself: 12 transformer layers,
attention run twice per layer over 1,335 time frames per 13-second chunk across
~60 bands, emitting 6 stems. Attention is quadratic in sequence length and
memory-bound on CPU, which is why throughput lands ~10x below peak GEMM.

No setting recovers it — `--mdxc_overlap` is already at its floor of 2. Published
"5–15 min" figures for this model are GPU-era numbers repeated without
measurement. `MAX_PER_RUN=3` and the 90-minute-per-track stage budget both derive
from the measured figure, so changing the model means revisiting both.

## Recovery

- Wrong track downloaded / bad stems: delete the CONTENTS of `<Artist>/<Track>/`
  on any device and leave the folder there. An empty folder is a request, so the
  next poll re-runs it. Deleting the whole folder forgets the track instead.
- A request that failed: open `<Artist>/<Track>/` and you will find
  `FAILED - <reason>.txt` saying what happened and when. **Delete that file to
  retry.** Nothing retries on its own — a Soulseek failure is usually a peer that
  went offline, and the note is there so a missed notification does not lose the
  request.
- A request that never seems to start: it is polled every 5 minutes, not watched,
  so allow that long before suspecting anything. `journalctl -u liquidroom.triage`
  shows every poll.
- A file dropped at the root of `master/liquidroom` does nothing at all and is
  left where it lies. The old `Artist - Track.txt` format retired on 2026-08-28;
  nothing sweeps, moves or reports one, because a file at the root cannot spin the
  timer the way it hot-looped the old `.path` unit. `rejected/` is no longer
  created — an existing one is inert and can be deleted.
- A track that sounds flat or narrow is usually the SOURCE, not the separation.
  Check it before blaming the pipeline: a real CD rip is 44,100 Hz, and a file at
  48,000 Hz almost certainly came from video or a stream. `sockseek` is now told to
  prefer 44.1 kHz / 16-bit / FLAC and to favour filenames carrying the artist and
  title, but these are PREFERENCES — if only a bad copy exists, a bad copy is what
  arrives. Empty the track folder (leave the folder) to re-request it.
- A failed batch's work dir sits under `state/work/<batch>/` with both stage
  logs; it self-purges after 7 days.
- ZFS/sanoid snapshot the whole pool; restic carries `syncthing/data` (stems
  included) to B2 nightly.
