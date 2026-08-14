# The liquidroom job image: Sockseek (Soulseek download) + audio-separator
# (BS-Roformer-SW, 6 stems) + MSST (listra92 lead/rhythm split) + ffmpeg.
# One image, two compose services (liquidroom / liquidroom-offline) that differ
# only in network policy. Never resident: every run is `compose run --rm`.
#
# Pinned by digest, not tag (capture precedent — a mutable tag silently adopts
# whatever it points at that day). No watchtower label, so the base moves only
# when this line is edited. Refresh deliberately:
#   docker buildx imagetools inspect python:3.12-slim   # take the index digest
FROM python:3.12-slim@sha256:dd29372629eeba2dd003fd9e9d35a5b8236c44727875a0364254b5127af88e65

RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

# TWO venvs, deliberately — audio-separator and MSST each pin their own torch
# constellation, and one shared site-packages is how an innocent `pip install`
# for one silently downgrades the other. Disk is cheap on this box; a dependency
# fight at 04:00 is not. CPU-index torch goes in FIRST in each venv so the
# multi-GB CUDA bundle never lands: both tools accept any torch >= their floor,
# and an already-satisfied requirement is not reinstalled.
RUN python -m venv /opt/venv-sep \
    && /opt/venv-sep/bin/pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu \
    && /opt/venv-sep/bin/pip install --no-cache-dir "audio-separator[cpu]==0.44.5"

# MSST is a repo, not a package. Pinned to the v1.0.21 release tag (2026-04-20)
# — the checkpoint's config was authored against this era of the code, and an
# unpinned clone re-fights that battle on every rebuild.
RUN git clone --depth 1 --branch v1.0.21 \
        https://github.com/ZFTurbo/Music-Source-Separation-Training /opt/msst \
    && python -m venv /opt/venv-msst \
    && /opt/venv-msst/bin/pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu \
    && /opt/venv-msst/bin/pip install --no-cache-dir -r /opt/msst/requirements.txt

# Sockseek: self-contained release binary, pinned by version AND sha256 (recorded
# from the GitHub release asset digest, 2026-08-14). AGPL; single file, no runtime.
ARG SOCKSEEK_VERSION=3.0.5
ARG SOCKSEEK_SHA256=d0a1e909297bc4aa0e497bfdd7203884945a78adfb3c0477c8f22830ac951b66
RUN curl -fsSL -o /tmp/sockseek.tar.gz \
        "https://github.com/fiso64/sockseek/releases/download/v${SOCKSEEK_VERSION}/sockseek_${SOCKSEEK_VERSION}_linux-x64.tar.gz" \
    && echo "${SOCKSEEK_SHA256}  /tmp/sockseek.tar.gz" | sha256sum -c \
    && tar -xzf /tmp/sockseek.tar.gz -C /tmp \
    && install -m 0755 "$(find /tmp -maxdepth 2 -name sockseek -type f | head -1)" /usr/local/bin/sockseek \
    && rm -rf /tmp/sockseek.tar.gz /tmp/sockseek*

COPY entrypoint.sh /usr/local/bin/liquidroom-entrypoint
COPY process.py /app/process.py
RUN chmod 0755 /usr/local/bin/liquidroom-entrypoint

# uid 1000 matches the host-owned state/ bind mounts (house convention). The
# rootfs is read_only at run time and HOME points at the tmpfs /tmp — that is
# where the sockseek conf (credentials) is rendered, and it dies with the run.
RUN useradd -u 1000 -M -s /usr/sbin/nologin liquidroom
USER liquidroom
ENV HOME=/tmp

ENTRYPOINT ["liquidroom-entrypoint"]
