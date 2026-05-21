# syntax=docker/dockerfile:1
# Builds a Godot engine binary from `v-sekai-multiplayer-fabric/godot` source.
# Parameterised over SCons target (editor or template_release) so the same
# Dockerfile produces both flavours via a CI matrix — see
# .github/workflows/build.yml.
#
# Build contexts:
#   godot-src — checkout of v-sekai-multiplayer-fabric/godot @ <ref>
#
# Build args:
#   TARGET       SCons `target=` value: `editor` or `template_release`
#   BINARY_NAME  Filename SCons writes under bin/, e.g.
#                  `godot.linuxbsd.editor.double.x86_64`
#                  `godot.linuxbsd.template_release.double.x86_64`
#
# Output: /usr/local/bin/godot (the named binary, renamed for ergonomics)

# ── Build stage ──────────────────────────────────────────────────────────────
FROM almalinux:9 AS build

ARG TARGET=editor
ARG BINARY_NAME=godot.linuxbsd.editor.double.x86_64

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

WORKDIR /build
COPY --from=godot-src . .

# SConstruct lives at the engine root in the v-sekai-multiplayer-fabric/godot
# layout (no nested godot/ subdir, unlike multiplayer-fabric-build).
RUN --mount=type=cache,target=/root/.cache/scons-godot \
    scons platform=linuxbsd \
        target="${TARGET}" \
        precision=double \
        accesskit=no \
        linuxbsd_speechd=no \
        cache_path=/root/.cache/scons-godot \
        -j"$(nproc)" \
    && strip "bin/${BINARY_NAME}"

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
