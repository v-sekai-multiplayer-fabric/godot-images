# Builds a Godot engine binary from `v-sekai-multiplayer-fabric/fabric-godot-core` source.
# Parameterised over SCons target (editor or template_release) so the same
# Dockerfile produces both flavours — see justfile recipes
# `build-docker-editor` / `build-docker-runtime`.
#
# Build contexts:
#   godot-src — checkout of v-sekai-multiplayer-fabric/fabric-godot-core @ <ref>
#
# Build args:
#   TARGET       SCons `target=` value: `editor` or `template_release`
#   BINARY_NAME  Filename SCons writes under bin/, e.g.
#                  `godot.linuxbsd.editor.double.x86_64`
#                  `godot.linuxbsd.template_release.double.x86_64`
#   SCCACHE_VERSION  pinned sccache release tag (kept as ARG so it's
#                    overridable without editing the Dockerfile)
#
# Output: /usr/local/bin/godot (the named binary, renamed for ergonomics)
#
# Caching: two buildx cache mounts back the build — SCons's file cache for
# unchanged build-graph nodes, and sccache for actual compiler output.
# Cache persists across `just build-docker` invocations on the same host
# and is shared between the editor and runtime invocations (large overlap:
# most of core/ and scene/ compile identically across target=editor vs
# target=template_release).

# ── Build stage ──────────────────────────────────────────────────────────────
FROM almalinux:9 AS build

ARG TARGET=editor
ARG BINARY_NAME=godot.linuxbsd.editor.double.x86_64
ARG SCCACHE_VERSION=v0.16.0
ARG SCCACHE_GHA_ENABLED=""

RUN dnf install -y 'dnf-command(config-manager)' && \
    dnf config-manager --set-enabled crb && \
    dnf install -y \
        gcc gcc-c++ make \
        python3 python3-pip \
        pkgconf-pkg-config \
        libX11-devel libXcursor-devel libXinerama-devel libXrandr-devel \
        libXi-devel mesa-libGL-devel \
        alsa-lib-devel pulseaudio-libs-devel \
        libstdc++-static \
        ca-certificates && \
    dnf clean all && \
    pip3 install scons

# Install sccache — used as compiler launcher to cache .o output across
# builds. Persisted via buildx cache mount on /root/.cache/sccache below.
RUN curl -fsSL "https://github.com/mozilla/sccache/releases/download/${SCCACHE_VERSION}/sccache-${SCCACHE_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        | tar -xz --strip-components=1 -C /usr/local/bin \
            "sccache-${SCCACHE_VERSION}-x86_64-unknown-linux-musl/sccache" && \
    chmod +x /usr/local/bin/sccache

ENV SCCACHE_DIR=/root/.cache/sccache
ENV SCCACHE_CACHE_SIZE=20G
# Normalise the engine source path so cache entries are reusable across
# the editor and runtime builds (both unpack /build but the actual
# compiler invocations reference absolute paths).
ENV SCCACHE_BASEDIRS=/build
# When set to "true" sccache uses the GitHub Actions cache service
# instead of the local disk cache (pass ACTIONS_CACHE_URL and
# ACTIONS_RUNTIME_TOKEN as build secrets alongside this arg).
ARG SCCACHE_GHA_ENABLED
ENV SCCACHE_GHA_ENABLED=${SCCACHE_GHA_ENABLED}
WORKDIR /build
COPY --from=godot-src . .

RUN --mount=type=secret,id=ACTIONS_CACHE_URL \
    --mount=type=secret,id=ACTIONS_RUNTIME_TOKEN \
    --mount=type=cache,target=/root/.cache/sccache,sharing=locked \
    export ACTIONS_CACHE_URL="$(cat /run/secrets/ACTIONS_CACHE_URL 2>/dev/null || true)" && \
    export ACTIONS_RUNTIME_TOKEN="$(cat /run/secrets/ACTIONS_RUNTIME_TOKEN 2>/dev/null || true)" && \
    scons platform=linuxbsd \
        target="${TARGET}" \
        precision=double \
        accesskit=no \
        linuxbsd_speechd=no \
        c_compiler_launcher=sccache \
        cpp_compiler_launcher=sccache \
        -j"$(nproc)" && \
    sccache --show-stats && \
    strip "bin/${BINARY_NAME}"

# ── Runtime stage: just the binary + minimal shared libs ─────────────────────
FROM almalinux:9

ARG BINARY_NAME

RUN dnf install -y \
        mesa-libGL alsa-lib pulseaudio-libs libstdc++ \
        fontconfig ca-certificates && \
    dnf clean all

COPY --from=build /build/bin/${BINARY_NAME} /usr/local/bin/godot
RUN chmod +x /usr/local/bin/godot \
    && /usr/local/bin/godot --version
