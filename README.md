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
  `MAX_PER_RUN=4` per run; anything beyond it is picked up by the next fire.

## Operations

```bash
bash liquidroom/tests/run.sh                    # offline suite (no docker, no ntfy)
docker compose build liquidroom                 # rebuild the job image (MANUAL —
                                                # no watchtower on local builds)
bash liquidroom/scripts/models.sh               # fetch/verify both models (~1 GB)
sudo systemctl start liquidroom.triage.service  # drain the root right now
journalctl -u liquidroom.triage.service -f      # watch a run
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
