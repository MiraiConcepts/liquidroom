#!/usr/bin/env python3
"""liquidroom batch worker: separate -> lead/rhythm split -> minus-one mixes.

Runs INSIDE the liquidroom-roformer container (network_mode: none) under the
audio-separator venv. One invocation per batch: the BS-Roformer-SW model is
loaded ONCE and every downloaded track in the batch runs through it — that
amortised load is the whole reason the pipeline batches.

Per-track failures append `fail` to the manifest and the loop continues; only a
batch-level impossibility (no spec, model missing) exits non-zero. The
lead/rhythm split and the mixes are NON-FATAL per track: their failure degrades
the slot to `ok_no_split`, never to `fail` — six stems that exist beat a perfect
result that doesn't.

Also runnable on the HOST (which has only stdlib python) as:
    python3 process.py --plan-mixes <stem-dir>
which prints the mix plan without touching audio — the offline test suite's
window into the mix arithmetic. Heavy imports are deferred into main() so this
mode needs nothing installed.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

STEMS = ["Vocals", "Drums", "Bass", "Guitar", "Piano", "Other"]
SEP_MODEL = "BS-Roformer-SW.ckpt"
SPLIT_CKPT = "/models/mbr_lead_rhythm_guitar_listra92.ckpt"
SPLIT_YAML = "/models/mbr_lead_rhythm_guitar_listra92_config.yaml"
MSST_PY = "/opt/venv-msst/bin/python"
MSST_INFER = "/opt/msst/inference.py"
AUDIO_EXT = (".flac", ".mp3", ".m4a", ".ogg", ".opus", ".wav", ".aiff", ".ape", ".wv")


def log(msg):
    print(msg, flush=True)


def manifest_append(batch_dir, idx, stage, status, detail=""):
    # Same TSV the host triage reads with awk; detail is single-line by
    # construction (host-validated names, our own short strings).
    detail = detail.replace("\t", " ").replace("\n", " ")[:200]
    with open(os.path.join(batch_dir, "manifest.tsv"), "a", encoding="utf-8") as f:
        f.write(f"{idx}\t{stage}\t{status}\t{detail}\n")


def read_spec(batch_dir):
    rows = []
    with open(os.path.join(batch_dir, "spec.tsv"), encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 3:
                rows.append((parts[0], parts[1], parts[2]))
    return rows


def dl_ok_slots(batch_dir):
    ok = set()
    path = os.path.join(batch_dir, "manifest.tsv")
    if not os.path.exists(path):
        return ok
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 3 and parts[1] == "dl":
                if parts[2] == "ok":
                    ok.add(parts[0])
                else:
                    ok.discard(parts[0])
    return ok


def base_from_stem(stem_path, stem):
    """Recover the base name the SEPARATOR used, from one of its own outputs.

    audio-separator sanitises characters it dislikes, so its outputs and ours
    can disagree and the published folder ends up with two spellings of one
    track, which also breaks combine.py (it parses a single base off the front
    of a stem set). This finds what the separator chose so the caller can rename
    it back to the base the HOST asked for, which is authoritative because the
    containing folder already carries it.

    Since 2026-08-21 the host's base is itself portable (portable_segment() in
    liquidroom.lib.sh applies the beets table, so "What Ever Happened?" arrives
    here already spelled "What Ever Happened_") and the separator therefore
    agrees with us on the reserved characters. This is kept anyway: what that
    tool sanitises is its own business and not something this repo controls, so
    it stays as the general repair, and a no-op when the two already agree.
    """
    name = os.path.basename(stem_path)
    marker = f"_({stem})_"
    idx = name.lower().find(marker.lower())
    return name[:idx] if idx > 0 else None


def find_stem(files, stem):
    """Match <base>_(Stem)_<model>.<ext> anchored at END of the basename.

    The naive `_(Stem)_` search would also match a requester-chosen track like
    "Song_(Drums)_x" appearing inside <base>, mis-binding stems. Anchoring to
    the model token + extension at the string end (the model names contain no
    ')' or space) defeats that: the injected "_(Drums)_x - artist..." is
    followed by more text, not by <model>.<ext>$.
    """
    pat = re.compile(r"_\(" + re.escape(stem) + r"\)_[A-Za-z0-9.-]+\.[A-Za-z0-9]+$",
                     re.IGNORECASE)
    for f in files:
        if pat.search(os.path.basename(f)):
            return f
    return None


def plan_mixes(stem_paths, lead=None, rhythm=None, base="track"):
    """Pure mix arithmetic — which inputs sum into which minus-one file.

    stem_paths: dict stem-name -> path for the six separator stems.
    Returns [(output-basename, [input paths...]), ...]. The five non-guitar
    stems are every mix's foundation; the guitar comes back in exactly one
    half at a time.
    """
    five = [stem_paths[s] for s in STEMS if s != "Guitar" and s in stem_paths]
    plans = [(f"{base} (-1 Guitar).mp3", list(five))]
    if rhythm:
        plans.append((f"{base} (-1 Lead Guitar).mp3", list(five) + [rhythm]))
    if lead:
        plans.append((f"{base} (-1 Rhythm Guitar).mp3", list(five) + [lead]))
    return plans


def run_ffmpeg_mix(out_path, inputs):
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]
    for p in inputs:
        cmd += ["-i", p]
    # normalize=0: preserve levels like combine.py's pydub overlay does — the
    # sum can clip, and that is the behaviour the owner's own tool has.
    cmd += ["-filter_complex", f"amix=inputs={len(inputs)}:normalize=0",
            "-codec:a", "libmp3lame", "-q:a", "2", out_path]
    subprocess.run(cmd, check=True, capture_output=True)


def to_wav(src, dst):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                    "-i", src, dst], check=True, capture_output=True)


def to_mp3(src, dst):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                    "-i", src, "-codec:a", "libmp3lame", "-q:a", "2", dst],
                   check=True, capture_output=True)


def split_guitar(guitar_mp3, base, out_dir):
    """MSST + listra92 on the guitar stem. Returns (lead_mp3, rhythm_mp3).

    The model outputs the Lead stem; --extract_instrumental adds the residual,
    which for a guitar-only input IS the rhythm. Output naming varies across
    MSST versions, so match by 'lead' in the name and take the other file as
    the residual rather than hardcoding either.
    """
    with tempfile.TemporaryDirectory(dir="/tmp") as td:
        in_dir = os.path.join(td, "in")
        out_wav = os.path.join(td, "out")
        os.makedirs(in_dir)
        os.makedirs(out_wav)
        to_wav(guitar_mp3, os.path.join(in_dir, "guitar.wav"))
        subprocess.run(
            [MSST_PY, MSST_INFER,
             "--model_type", "mel_band_roformer",
             "--config_path", SPLIT_YAML,
             "--start_check_point", SPLIT_CKPT,
             "--input_folder", in_dir,
             "--store_dir", out_wav,
             "--extract_instrumental",
             "--force_cpu"],
            check=True, capture_output=True)
        wavs = []
        for root, _dirs, files in os.walk(out_wav):
            wavs += [os.path.join(root, f) for f in files if f.lower().endswith(".wav")]
        if len(wavs) < 2:
            raise RuntimeError(f"split produced {len(wavs)} file(s), expected 2")
        lead_wav = next((w for w in wavs if "lead" in os.path.basename(w).lower()), None)
        if lead_wav is None:
            raise RuntimeError("no output file identifies as lead")
        rhythm_wav = next(w for w in wavs if w != lead_wav)
        lead_mp3 = os.path.join(out_dir, f"{base}_(Lead Guitar)_listra92.mp3")
        rhythm_mp3 = os.path.join(out_dir, f"{base}_(Rhythm Guitar)_listra92.mp3")
        to_mp3(lead_wav, lead_mp3)
        to_mp3(rhythm_wav, rhythm_mp3)
        return lead_mp3, rhythm_mp3


def process_batch(batch_dir):
    from audio_separator.separator import Separator  # heavy; container-only

    spec = read_spec(batch_dir)
    todo = dl_ok_slots(batch_dir)
    work = [(i, a, t) for (i, a, t) in spec if i in todo]
    if not work:
        log("nothing to process")
        return 0

    sep_out = os.path.join(batch_dir, "sepout")
    os.makedirs(sep_out, exist_ok=True)
    log(f"loading {SEP_MODEL} (once for {len(work)} track(s))")
    separator = Separator(
        model_file_dir="/models",
        output_dir=sep_out,
        output_format="mp3",
        mdxc_params={"segment_size": 256, "override_model_segment_size": False,
                     "batch_size": 1, "overlap": 2, "pitch_shift": 0},
    )
    separator.load_model(model_filename=SEP_MODEL)

    for idx, artist, track in work:
        # Provisional — replaced below by whatever the separator actually used,
        # so every file in the published folder shares one base name.
        base = f"{track} - {artist}"
        tdir = os.path.join(batch_dir, f"t{idx}")
        dl_dir = os.path.join(tdir, "dl")
        publish = os.path.join(tdir, "publish")
        try:
            audio = [os.path.join(dl_dir, f) for f in os.listdir(dl_dir)
                     if f.lower().endswith(AUDIO_EXT)]
            if len(audio) != 1:
                manifest_append(batch_dir, idx, "proc", "fail",
                                f"expected 1 downloaded file, found {len(audio)}")
                continue
            original = audio[0]

            log(f"[{idx}] separating {os.path.basename(original)}")
            outputs = separator.separate(original)
            # audio-separator may return paths relative to output_dir
            outputs = [o if os.path.isabs(o) else os.path.join(sep_out, o)
                       for o in outputs]
            stem_paths = {}
            for s in STEMS:
                p = find_stem(outputs, s)
                if p:
                    stem_paths[s] = p
            if len(stem_paths) != len(STEMS):
                manifest_append(batch_dir, idx, "proc", "fail",
                                f"{len(stem_paths)}/6 stems produced")
                continue

            # The HOST's base wins. The separator may have sanitised it, which
            # would leave the folder holding two spellings of one track. Rather
            # than adopt the mangled one, rename its outputs back: the containing
            # folder already carries our spelling. That spelling is now portable
            # before it ever reaches this container — the 2026-08-15 "the
            # requested title is authoritative, every device handles ? fine"
            # call held only while every device ran a real filesystem, and the
            # Windows peer sat out of sync for two days over one "?". See
            # portable_segment() in liquidroom.lib.sh.
            sep_base = base_from_stem(stem_paths["Vocals"], "Vocals")
            if sep_base and sep_base != base:
                log(f"[{idx}] separator wrote {sep_base!r}; renaming back to {base!r}")

            os.makedirs(publish, exist_ok=True)
            lead = rhythm = None
            split_err = ""
            try:
                log(f"[{idx}] splitting guitar stem into lead/rhythm")
                lead, rhythm = split_guitar(stem_paths["Guitar"], base, publish)
            except Exception as e:  # noqa: BLE001 — non-fatal by design
                split_err = str(e)[:150]
                log(f"[{idx}] split failed (non-fatal): {split_err}")

            for name, inputs in plan_mixes(stem_paths, lead, rhythm, base):
                try:
                    run_ffmpeg_mix(os.path.join(publish, name), inputs)
                except subprocess.CalledProcessError as e:
                    log(f"[{idx}] mix '{name}' failed (non-fatal): {e}")

            # Publish the stems under the requested title, swapping the
            # separator's prefix for ours so all twelve files agree.
            for s, p in stem_paths.items():
                name = os.path.basename(p)
                if sep_base and name.startswith(sep_base):
                    name = base + name[len(sep_base):]
                shutil.move(p, os.path.join(publish, name))
            shutil.move(original, os.path.join(
                publish, f"{base}{os.path.splitext(original)[1]}"))

            if lead and rhythm:
                manifest_append(batch_dir, idx, "proc", "ok")
            else:
                manifest_append(batch_dir, idx, "proc", "ok_no_split",
                                split_err or "split unavailable")
            log(f"[{idx}] done")
        except Exception as e:  # noqa: BLE001 — one bad track must not sink the batch
            manifest_append(batch_dir, idx, "proc", "fail", str(e)[:200])
            log(f"[{idx}] FAILED: {e}")
    return 0


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--plan-mixes":
        # Host-side test mode: stem dir in, mix plan out, no audio touched.
        d = sys.argv[2]
        files = [os.path.join(d, f) for f in sorted(os.listdir(d))]
        stem_paths = {s: p for s in STEMS if (p := find_stem(files, s))}
        lead = find_stem(files, "Lead Guitar")
        rhythm = find_stem(files, "Rhythm Guitar")
        for name, inputs in plan_mixes(stem_paths, lead, rhythm, "track"):
            print(f"{name}\t{len(inputs)}\t" + "\t".join(os.path.basename(i) for i in inputs))
        return 0
    if len(sys.argv) == 2:
        return process_batch(sys.argv[1])
    print("usage: process.py <batch-dir> | --plan-mixes <stem-dir>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
