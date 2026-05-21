# syntax=docker/dockerfile:1
# Builds a Godot engine binary from `v-sekai-multiplayer-fabric/godot` source.
# Parameterised over SCons target (editor or template_release) so the same
# Dockerfile produces both flavours — see justfile recipes
# `build-docker-editor` / `build-docker-runtime`.
#
# Build contexts:
#   godot-src — checkout of v-sekai-multiplayer-fabric/godot @ <ref>
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
ARG SCCACHE_VERSION=v0.8.2

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
# Non-sensitive sccache backend configuration travels as build-args.
# The actual AWS credentials come in via BuildKit `--secret` mounts on
# the RUN line below (see justfile `_sccache_secretargs` and the CI
# workflow) so they never bake into image layers.
ARG SCCACHE_BUCKET=""
ARG SCCACHE_ENDPOINT=""
ARG SCCACHE_REGION=""
ENV SCCACHE_BUCKET=${SCCACHE_BUCKET}
ENV SCCACHE_ENDPOINT=${SCCACHE_ENDPOINT}
ENV SCCACHE_REGION=${SCCACHE_REGION}

WORKDIR /build
COPY --from=godot-src . .

# SConstruct lives at the engine root in the v-sekai-multiplayer-fabric/godot
# layout (no nested godot/ subdir, unlike multiplayer-fabric-build).
# AWS_* envs are sourced from BuildKit secret files at /run/secrets/* —
# they're only present for the duration of this RUN and never persist
# into a layer. If the secrets are absent (no Tigris configured),
# sccache silently falls back to the local buildx cache mount.
RUN --mount=type=cache,target=/root/.cache/scons-godot,sharing=locked \
    --mount=type=cache,target=/root/.cache/sccache,sharing=locked \
    --mount=type=secret,id=aws_access_key_id \
    --mount=type=secret,id=aws_secret_access_key \
    sh -eu -c '\
        if [ -s /run/secrets/aws_access_key_id ]; then \
            export AWS_ACCESS_KEY_ID="$(cat /run/secrets/aws_access_key_id)"; \
            export AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/aws_secret_access_key)"; \
        fi; \
        scons platform=linuxbsd \
            target="${TARGET}" \
            precision=double \
            accesskit=no \
            linuxbsd_speechd=no \
            cache_path=/root/.cache/scons-godot \
            c_compiler_launcher=sccache \
            cpp_compiler_launcher=sccache \
            -j"$(nproc)" && \
        sccache --show-stats && \
        strip "bin/${BINARY_NAME}" \
    '

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
