# liquidroom

Request a track by name from any synced device; get its stems back everywhere.

```
you, anywhere ──▶ master/liquidroom/The Strokes - What Ever Happened?.txt   (empty file)
                        │  liquidroom.triage.path fires on *.txt
                        ▼
                  liquidroom.triage.service (host, batched)
                        │  1. Sockseek downloads from Soulseek (FLAC preferred)
                        │  2. BS-Roformer-SW cuts 6 stems (world #1 for guitar)
                        │  3. listra92 model splits the guitar stem: lead / rhythm
                        │  4. ffmpeg builds three minus-one practice mixes
                        ▼
                  master/liquidroom/The Strokes/What Ever Happened?/
                        │  original + 6 stems + lead/rhythm + 3 mixes
                        ▼
                  synced to every device; one ntfy push on the `liquidroom` topic
```

## The request contract

- **The NAME is the request**: an empty file called `Artist - Track.txt` at the
  folder root. Split is on the **first** ` - `; both halves are trimmed.
  `Daft Punk - One More Time - Live.txt` is artist `Daft Punk`, track
  `One More Time - Live`. Japanese and punctuation are fine.
- The marker **disappearing from your devices is the receipt** — it is deleted
  once its outcome is decided (published, failed, already-exists). The ntfy
  push carries the outcome either way.
- Anything at the root that is **not** an understood request — wrong extension,
  a file with actual content, an unparseable or unsafe name — is parked in
  `rejected/`, visible on every device, and **never deleted automatically**.
- A request whose `<Artist>/<Track>/` folder already exists is skipped
  ("already exists"), costing nothing.
- Several requests queued together run as **one batch**: one download
  container, one processing container, the model loaded once. The cap is
  `MAX_PER_RUN=3` per run; anything beyond it is picked up by the next fire.

## Speed — measured, not estimated

**~31 minutes for a 3:20 track** (measured 2026-08-14 on this box; roughly 9.4x
realtime, so budget ~35–40 min for a typical song and ~1.5 h for a batch of 3).

That is the honest number, and published "5–15 min" figures for this model are
GPU-era numbers repeated without measurement. Diagnosed rather than assumed —
the hardware is fine: raw FP32 GEMM measures **520 GFLOPS** (~60% of this chip's
theoretical peak), torch uses AVX-512 with MKL on all 6 physical cores, and the
container has no CPU quota. The cost is the model itself: 12 transformer layers,
attention run twice per layer over 1,335 time frames per 13-second chunk across
~60 bands, emitting 6 stems. Attention is quadratic in sequence length and
memory-bound on CPU, which is why throughput lands ~10x below peak GEMM.

No setting recovers it — `--mdxc_overlap` is already at its floor of 2. The only
real lever is a different model: `htdemucs_6s` (convolutional, far faster, also
6 stems) at materially worse guitar quality — BS-Roformer-SW leads the MVSep
guitar leaderboard at 9.01 SDR while htdemucs_6s does not place in the top 20.
Guitar quality is the whole point of this pipeline, so slow-and-good is the
deliberate default. Switching is one line in `process.py` (`SEP_MODEL`).

## Operations

```bash
# FIRST INSTALL ONLY — create the drop folder. The triage makes it on its first
# run, but you cannot drop a request into a directory that does not exist yet,
# and the .path unit has nothing to watch until it does.
mkdir -p /zpool/catallenya/syncthing/data/master/liquidroom/rejected

bash liquidroom/tests/run.sh                    # offline suite (no docker, no ntfy)
docker compose build liquidroom                 # rebuild the job image (MANUAL —
                                                # no watchtower on local builds)
bash liquidroom/scripts/models.sh               # fetch/verify both models (~1 GB)
# Force a run now. --no-block is not optional in practice: without it systemctl
# WAITS for the oneshot to finish, so the terminal sits silent for the ~35 min a
# separation takes and reads exactly like a hang. Ctrl-C there only detaches the
# client — the job keeps running, and a second `start` is a no-op while it does.
sudo systemctl start --no-block liquidroom.triage.service
journalctl -u liquidroom.triage.service -f      # watch a run (Ctrl-C is safe)

# After a run of rapid failures, BOTH units trip the class start limit (12 starts
# / 30 min) — and resetting only the service leaves the WATCHER dead, so the next
# dropped request is never noticed. `systemctl status` shows this as
# "TriggeredBy: × liquidroom.triage.path". Reset the pair, always:
sudo systemctl reset-failed liquidroom.triage.path liquidroom.triage.service
# Both also self-heal: the 30-minute window slides, so an untouched pair recovers
# on its own. reset-failed is only for when you do not want to wait.
sudo bash liquidroom/uninstall.sh               # zero-artifact teardown
```

- Runtime state lives in `liquidroom/state/` (gitignored): `work/` per-batch
  spool — failed batches keep their dirs (and `download.log`/`process.log`)
  for 7 days as autopsies — and `models/` (two checkpoints, sha256-pinned in
  `scripts/models.sh`).
- Credentials: `/etc/liquidroom.env` (root 0600) with `SLSK_USER`/`SLSK_PASS`.
  A **dedicated** Soulseek account — the server kicks the older session when a
  name logs in twice, so never reuse the desktop account. First login claims
  the name; ~30 days idle and it lapses.
- The two compose services share one image and differ only in network policy:
  `liquidroom` (own bridge network, port 50300 published only during downloads)
  and `liquidroom-offline` (`network_mode: none` — the inference stages need no
  network, so the community checkpoint physically cannot phone home).
- Sockseek is a pinned release binary inside the image. Its CLI surface was
  researched, not yet verified against a live run — before first use:
  `docker compose run --rm liquidroom sockseek-help`, then fix
  `entrypoint.sh` if any flag or conf key is spelled differently.
- The lead/rhythm split (`listra92`, community model, no published SDR) is
  **non-fatal**: if it fails or disappoints, tracks still publish with 6 stems
  and the plain `(-1 Guitar)` mix, and the notification says so. Disabling it
  entirely is a one-line change in `process.py` (`split_guitar` call).
- Router port-forward of TCP 50300 to this box is optional but makes downloads
  from passive peers reliable; without it Sockseek's candidate fallback
  usually recovers at the cost of a retry.

## Recovery

- Wrong track downloaded / bad stems: delete `<Artist>/<Track>/` on any device
  and drop the marker again — the skip-if-exists check is on the folder.
- A failed batch's work dir sits under `state/work/<batch>/` with both stage
  logs; it self-purges after 7 days.
- ZFS/sanoid snapshot the whole pool; restic carries `syncthing/data` (stems
  included) to B2 nightly.
