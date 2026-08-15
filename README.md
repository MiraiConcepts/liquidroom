# liquidroom

> Mirror of [`carrein/catallenya`](https://github.com/carrein/catallenya) →
> `liquidroom/`. Force-synced by CI — open issues and pull requests on the parent
> repo, not here.

Request a track by name from any synced device; get its stems back everywhere.

```
you, anywhere ──▶ <drop folder>/The Strokes - What Ever Happened?.txt   (empty file)
                        │  a path unit fires on *.txt
                        ▼
                  triage (host, batched)
                        │  1. Sockseek downloads from Soulseek (FLAC preferred)
                        │  2. BS-Roformer-SW cuts 6 stems (world #1 for guitar)
                        │  3. listra92 model splits the guitar stem: lead / rhythm
                        │  4. ffmpeg builds three minus-one practice mixes
                        ▼
                  <drop folder>/The Strokes/What Ever Happened?/
                        │  original + 6 stems + lead/rhythm + 3 mixes
                        ▼
                  synced to every device; one push notification per run
```

## The request contract

- **The NAME is the request**: an empty file called `Artist - Track.txt` at the
  folder root. Split is on the **first** ` - `; both halves are trimmed.
  `Daft Punk - One More Time - Live.txt` is artist `Daft Punk`, track
  `One More Time - Live`. Japanese and punctuation are fine.
- The marker **disappearing from your devices is the receipt** — it is deleted
  once its outcome is decided (published, failed, already-exists). The
  notification carries the outcome either way.
- Anything at the root that is **not** an understood request — wrong extension,
  a file with actual content, an unparseable or unsafe name — is parked in
  `rejected/`, visible on every device, and **never deleted automatically**.
- A request whose `<Artist>/<Track>/` folder already exists is skipped, costing
  nothing.
- Several requests queued together run as **one batch**: one download container,
  one processing container, the model loaded once. That amortisation is why the
  stages batch rather than running per track.
- The lead/rhythm guitar split is **non-fatal**: if it fails, tracks still publish
  with 6 stems and the plain minus-one guitar mix, and the notification says so.
- Publication is **one atomic rename**, so a sync client never observes a
  half-written folder.

## Why it is slow, on purpose

**~31 minutes for a 3:20 track** — roughly 9.4x realtime, measured rather than
estimated. That is a deliberate trade, not a fault.

BS-Roformer-SW leads the MVSep guitar leaderboard at 9.01 SDR. The fast
alternative, a convolutional model producing the same 6 stems, does not place in
that leaderboard's top 20. Guitar quality is the entire point of this pipeline, so
slow-and-good is the default and the speed figure is a consequence of that choice.
Published "5–15 min" numbers for this model are GPU figures.

## Isolation

Two container definitions share **one image** and differ only in network policy:

- **Downloader** — rides its own private bridge, never the host's shared network,
  because it talks to arbitrary Soulseek peers. Its peer-listen port is published
  only for the minutes a download lasts.
- **Separation, guitar split and mixes** — run with **no network at all**. These
  stages need none, and the lead/rhythm checkpoint is a community model, so
  running it disconnected means even a malicious pickle has nowhere to phone home.

Both drop all capabilities, run read-only and non-root, and are capped at 10 GB.
Neither is a resident service: they exist only for the minutes a run lasts.

## What bounds a run

- The job container runs in the container daemon's cgroup, **not the triggering
  unit's**. Per-stage timeouts, a fixed container name and a forced remove on both
  entry and exit are what bound a run — the unit's own start timeout does not
  reach it. This is the least obvious constraint in the pipeline.
- **The requested title is authoritative.** The separator sanitises characters it
  dislikes — `?` comes back as `_` — so its outputs are renamed back on publish.
  All twelve files in a published folder share one base name, and downstream
  parsing depends on that.
- The two container definitions are behind a compose profile, so they are
  invisible to the host's normal boot-time bring-up and are activated only by the
  triage running them. They will never appear in a routine container listing.

## Scope

A component of [catallenya](https://github.com/carrein/catallenya), published for
reading rather than installation. It is not standalone: it expects a specific host
filesystem layout, container definitions that live in the parent repository's
compose file, and a systemd policy contract it inherits rather than declares.

Running it, and every trap worth knowing before you do, is in
[OPERATIONS.md](OPERATIONS.md).
