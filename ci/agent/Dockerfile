# Custom TeamCity Linux Build Agent — stock image + Perforce CLI + C++ toolchain + Python/Pillow.
#
# Three reasons this image exists:
#
# 1. Perforce CLI. TeamCity's Perforce VCS root has two execution paths:
#    server-side Java client (VCS polling + Test Connection) and agent-side
#    external `p4` binary (sync). The stock jetbrains/teamcity-agent image
#    ships no `p4`, so a green Test Connection still fails at sync time.
#    See ci/lessons-learned.md §2.
#
# 2. C++ toolchain. The stock agent image is Java-focused — no cmake, no
#    g++, no make. The seed project at //game/main is C++ + CMake, so
#    the Compile stage needs the toolchain present before it can run.
#
# 3. Python 3 + Pillow. The Cook Data stage runs the Track-5 cooker
#    (pipeline/cook.py), which needs Python 3 + Pillow (texture mips). The
#    stock image has neither, so a cook step would fail at import time.
#
# p4 and the C++ toolchain are pinned where possible: p4 to the same family as the
# Track 1 broker (P4BROKER/NTX64/2025.2), and the OS toolchain to whatever
# the base image's Ubuntu repos pin at build time (`apt-get install`
# without a version pin — acceptable for a sandbox, would be pinned with
# a lockfile or PPA in production).

ARG TEAMCITY_VERSION=latest
FROM jetbrains/teamcity-agent:${TEAMCITY_VERSION}

ARG P4_RELEASE=r25.2
ARG P4_PLATFORM=bin.linux26x86_64

# Upstream image runs as `buildagent` (uid 1000); /usr/local/bin and apt
# are root-only. Switch to root for the installs, back to buildagent at
# the end so the rest of the image matches upstream behavior.
USER root

# C++ toolchain — `build-essential` brings g++, gcc, make, libc6-dev;
# `cmake` is its own package. --no-install-recommends keeps the layer
# small; apt cache cleanup in the same RUN keeps it from shipping.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
 && rm -rf /var/lib/apt/lists/* \
 && cmake --version \
 && g++ --version \
 && make --version

# Perforce CLI. `p4 -V` at build time so a 404 / bad checksum fails the
# image build loudly instead of at first sync.
RUN curl -fsSL "https://filehost.perforce.com/perforce/${P4_RELEASE}/${P4_PLATFORM}/p4" \
      -o /usr/local/bin/p4 \
 && chmod +x /usr/local/bin/p4 \
 && /usr/local/bin/p4 -V

# Python 3 + Pillow for the Cook Data stage (Track-5 cooker, pipeline/cook.py).
# Modern Pillow ships manylinux wheels, so no libjpeg/zlib -dev build deps are
# needed. PEP 668 marks the system Python "externally managed", so installing
# system-wide into this dedicated agent image needs --break-system-packages.
# The build-time `import PIL` fails the image build loudly if the wheel didn't land.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-pip \
 && pip3 install --no-cache-dir --break-system-packages pillow \
 && rm -rf /var/lib/apt/lists/* \
 && python3 -c "import PIL; print('Pillow', PIL.__version__)"

USER buildagent
