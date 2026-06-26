# Build recipes for v-sekai-multiplayer-fabric/godot — cross-compile from
# Linux to every supported platform, or build natively where simpler.
# Local-first: there's no CI workflow; developers run these recipes on
# their own machine and (for the editor + runtime Docker images) push the
# results to ghcr.io with `just push-docker`.
#
# Engine source is cloned into ./godot at the pinned tag below; override
# the directory with $GODOT_DIR or the ref with `just fetch-godot <ref>`.

# ─── Pinned engine ref ─────────────────────────────────────────────────
# Bump when a new tag from
# https://github.com/v-sekai-multiplayer-fabric/godot/tags should
# propagate downstream. `just fetch-godot` clones at this ref.
export GODOT_PINNED_REF := "v2026.06.22.1838-multiplayer-fabric"
export GODOT_REPO := "https://github.com/v-sekai-multiplayer-fabric/godot.git"

# ─── ghcr.io image names ───────────────────────────────────────────────
# Matches the FROM lines in the consumer repos (zone-baker, zone-server).
export DOCKER_EDITOR_IMAGE := "ghcr.io/v-sekai-multiplayer-fabric/godot-editor-double"
export DOCKER_RUNTIME_IMAGE := "ghcr.io/v-sekai-multiplayer-fabric/zone-godot-runtime"

export OPERATING_SYSTEM := os()
export WORLD_PWD := invocation_directory()
export GODOT_DIR := env_var_or_default("GODOT_DIR", "godot")
export ANDROID_NDK_VERSION := "23.2.8568313"
export OPENXR_LOADER_VERSION := env_var_or_default("OPENXR_LOADER_VERSION", "1.1.49")
export arm64toolchain := "https://github.com/godotengine/buildroot/releases/download/godot-2023.08.x-4/aarch64-godot-linux-gnu_sdk-buildroot.tar.bz2"
export cmdlinetools := "commandlinetools-linux-11076708_latest.zip"

export ARM64_ROOT := WORLD_PWD + "/aarch64-godot-linux-gnu_sdk-buildroot"
export ANDROID_SDK_ROOT := WORLD_PWD + "/android_sdk"
export ANDROID_HOME := ANDROID_SDK_ROOT
export JAVA_HOME := WORLD_PWD + "/jdk"
export VULKAN_SDK_ROOT := WORLD_PWD + "/vulkan_sdk/"
export EMSDK_ROOT := WORLD_PWD + "/emsdk"
export OSXCROSS_ROOT := WORLD_PWD + "/osxcross"
export MINGW_PREFIX := WORLD_PWD + "/mingw"

# Default recipe: fetch the engine at the pinned tag and build both
# ghcr.io images (editor + runtime). Run `just --list` to see every recipe.
default: fetch-godot build-docker

# ── Engine source ────────────────────────────────────────────────────────

# Clone (or update) the godot fork at the pinned tag.
# Override the ref with `just fetch-godot <ref>`.
#
# Uses --depth=1 --branch <ref> --single-branch so only the tree at one
# tag is fetched (one packfile, no commit history, no demand-loading of
# blobs). Much faster than `git clone --filter=blob:none` + checkout for
# a single-tag build because there's only one round-trip and the
# checkout reads from the local packfile instead of issuing per-blob
# lazy fetches against the remote.
fetch-godot ref=GODOT_PINNED_REF:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "${WORLD_PWD}"
    if [ -d "${GODOT_DIR}/.git" ]; then
        cd "${GODOT_DIR}"
        # Already cloned. Only hit the network if the ref isn't local.
        if git rev-parse --verify "{{ref}}" >/dev/null 2>&1; then
            git checkout --detach "$(git rev-parse "{{ref}}^{commit}" 2>/dev/null || echo "{{ref}}")"
        else
            # Shallow-fetch just this ref into the existing repo. Try as
            # a tag first; fall back to a branch ref name.
            git fetch --depth=1 origin "refs/tags/{{ref}}:refs/tags/{{ref}}" 2>/dev/null \
                || git fetch --depth=1 origin "{{ref}}"
            git checkout --detach "$(git rev-parse FETCH_HEAD^{commit})"
        fi
    else
        git clone --depth=1 --single-branch \
            "${GODOT_REPO}" "${GODOT_DIR}"
        cd "${GODOT_DIR}"
        git fetch --depth=1 origin "refs/tags/{{ref}}:refs/tags/{{ref}}" 2>/dev/null \
            || git fetch --depth=1 origin "{{ref}}"
        git checkout --detach "$(git rev-parse "FETCH_HEAD^{commit}" 2>/dev/null || git rev-parse FETCH_HEAD)"
    fi
    git rev-parse --short HEAD

# ── Toolchain setup ──────────────────────────────────────────────────────

fetch-llvm-mingw-macos:
    #!/usr/bin/env bash
    if [ ! -d "${MINGW_PREFIX}" ]; then
        cd $WORLD_PWD
        mkdir -p ${MINGW_PREFIX}
        curl -o llvm-mingw.tar.xz -L https://github.com/mstorsjo/llvm-mingw/releases/download/20241030/llvm-mingw-20241030-ucrt-macos-universal.tar.xz
        tar --dereference -xf llvm-mingw.tar.xz -C ${MINGW_PREFIX} --strip 1
        rm -rf llvm-mingw.tar.xz
    fi


fetch-llvm-mingw:
    #!/usr/bin/env bash
    if [ ! -d "${MINGW_PREFIX}" ]; then
        cd $WORLD_PWD
        mkdir -p ${MINGW_PREFIX}
        curl -o llvm-mingw.tar.xz -L https://github.com/mstorsjo/llvm-mingw/releases/download/20240917/llvm-mingw-20240917-ucrt-ubuntu-20.04-x86_64.tar.xz
        tar --dereference -xf llvm-mingw.tar.xz -C ${MINGW_PREFIX} --strip 1
        rm -rf llvm-mingw.tar.xz
    fi

setup-d3d12:
    #!/usr/bin/env bash
    cd $WORLD_PWD/$GODOT_DIR
    if [ ! -d "bin/build_deps/mesa" ] || [ ! -d "bin/build_deps/agility_sdk" ]; then
        python3 misc/scripts/install_d3d12_sdk_windows.py --mingw_prefix=${MINGW_PREFIX}
    fi

fetch-openjdk:
    #!/usr/bin/env bash
    if [ ! -d "${JAVA_HOME}" ]; then
        curl --fail --location --silent --show-error "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.11%2B9/OpenJDK17U-jdk_$(uname -m | sed -e s/86_//g)_linux_hotspot_17.0.11_9.tar.gz" --output jdk.tar.gz
        mkdir -p {{JAVA_HOME}}
        tar --dereference -xf jdk.tar.gz -C {{JAVA_HOME}} --strip 1
        rm -rf jdk.tar.gz
    fi

fetch-vulkan-sdk:
    #!/usr/bin/env bash
    if [ ! -d "${VULKAN_SDK_ROOT}" ]; then
        curl -L "https://github.com/godotengine/moltenvk-osxcross/releases/download/vulkan-sdk-1.3.283.0-2/MoltenVK-all.tar" -o vulkan-sdk.zip
        mkdir -p ${VULKAN_SDK_ROOT}
        tar -xf vulkan-sdk.zip -C {{VULKAN_SDK_ROOT}}
        rm vulkan-sdk.zip
    fi

fetch-android-openxr-loader:
    #!/usr/bin/env bash
    set -euo pipefail
    DEST="${GODOT_DIR}/platform/android/java/lib/libs/release/arm64-v8a"
    if [ ! -d "$DEST" ]; then
        echo "run after the android scons build (missing: $DEST)"
        exit 1
    fi
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    curl -fsSL -o "$TMP/loader.aar" \
        "https://repo1.maven.org/maven2/org/khronos/openxr/openxr_loader_for_android/${OPENXR_LOADER_VERSION}/openxr_loader_for_android-${OPENXR_LOADER_VERSION}.aar"
    unzip -qo "$TMP/loader.aar" -d "$TMP"
    cp "$TMP/jni/arm64-v8a/libopenxr_loader.so" "$DEST/"
    echo "bundled Khronos OpenXR loader ${OPENXR_LOADER_VERSION} → $DEST"

setup-android-sdk:
    #!/usr/bin/env bash
    if [ ! -d "${ANDROID_SDK_ROOT}" ]; then
        mkdir -p {{ANDROID_SDK_ROOT}}
        if [ ! -d "{{WORLD_PWD}}/{{cmdlinetools}}" ]; then
            curl -LO https://dl.google.com/android/repository/{{cmdlinetools}} -o {{WORLD_PWD}}/{{cmdlinetools}}
            cd {{WORLD_PWD}} && unzip -o {{WORLD_PWD}}/{{cmdlinetools}}
            rm {{WORLD_PWD}}/{{cmdlinetools}}
            yes | {{WORLD_PWD}}/cmdline-tools/bin/sdkmanager --sdk_root={{ANDROID_SDK_ROOT}} --licenses
            yes | {{WORLD_PWD}}/cmdline-tools/bin/sdkmanager --sdk_root={{ANDROID_SDK_ROOT}} "ndk;{{ANDROID_NDK_VERSION}}" 'cmdline-tools;latest' 'build-tools;34.0.0' 'platforms;android-34' 'cmake;3.22.1'
        fi
    fi

setup-emscripten:
    #!/usr/bin/env bash
    if [ ! -d "${EMSDK_ROOT}" ]; then
        git clone https://github.com/emscripten-core/emsdk.git $EMSDK_ROOT
        cd $EMSDK_ROOT
        ./emsdk install 4.0.11
        ./emsdk activate 4.0.11
    fi

setup-arm64:
    #!/usr/bin/env bash
    curl -LO "${arm64toolchain}" && \
    tar xf aarch64-godot-linux-gnu_sdk-buildroot.tar.bz2 && \
    rm -f aarch64-godot-linux-gnu_sdk-buildroot.tar.bz2 && \
    cd aarch64-godot-linux-gnu_sdk-buildroot && \
    ./relocate-sdk.sh

deploy_osxcross:
    #!/usr/bin/env bash
    git clone https://github.com/tpoechtrager/osxcross.git || true
    cd osxcross
    ./tools/gen_sdk_package.sh

build-osxcross:
    #!/usr/bin/env bash
    if [ ! -d "${OSXCROSS_ROOT}" ]; then
        git clone https://github.com/tpoechtrager/osxcross.git
        curl -o $OSXCROSS_ROOT/tarballs/MacOSX15.0.sdk.tar.xz -L https://github.com/V-Sekai/world/releases/download/v0.0.1/MacOSX15.0.sdk.tar.xz
        ls -l $OSXCROSS_ROOT/tarballs/
        cd $OSXCROSS_ROOT && UNATTENDED=1 ./build.sh && ./build_compiler_rt.sh
    fi

nil:
    echo "nil: Suceeded."

install_packages:
    if dnf >/dev/null 2>&1; then \
        dnf install -y hyperfine vulkan xz bzip2 file gcc gcc-c++ zlib-devel libmpc-devel mpfr-devel gmp-devel clang just parallel scons mold pkgconfig libX11-devel libXcursor-devel libXrandr-devel libXinerama-devel libXi-devel wayland-devel mesa-libGL-devel mesa-libGLU-devel alsa-lib-devel pulseaudio-libs-devel libudev-devel libstdc++-static libatomic-static cmake ccache patch libxml2-devel openssl openssl-devel git unzip; \
    else \
        sudo apt install -y build-essential hyperfine vulkan-tools xz-utils bzip2 file gcc zlib1g-dev libmpc-dev libmpfr-dev libgmp-dev clang just parallel scons mold pkg-config libx11-dev libxcursor-dev libxrandr-dev libxinerama-dev libxi-dev libwayland-dev libgl1-mesa-dev libglu1-mesa-dev libasound2-dev libpulse-dev libudev-dev cmake ccache patch libxml2-dev openssl libssl-dev git unzip; \
    fi

# ── Build ────────────────────────────────────────────────────────────────
# build-platform-target dispatches to the right scons invocation for the
# named platform. On Windows the recipe defaults to llvm-mingw cross-
# compile (from Linux); set USE_MINGW=no in the environment to use native
# MSVC on a Windows host instead.

build-platform-target platform target arch="auto" precision="double" osx_bundle="yes" extra_options="":
    #!/usr/bin/env bash
    set -o xtrace
    cd $WORLD_PWD
    if [[ "{{platform}}" == "web" && -d "$EMSDK_ROOT" ]]; then
        source "$EMSDK_ROOT/emsdk_env.sh"
    fi
    HOST_ARCH=$( uname -m )
    echo "HOST ARCHITECTURE: ${HOST_ARCH}"
    if [[ "{{arch}}" == "arm64" && ${HOST_ARCH} == 'x86_64' && "{{platform}}" == "linuxbsd" ]]; then
        rename 'aarch64-godot-linux-gnu-' '' ${ARM64_ROOT}/bin/*;
        export PATH="$ARM64_ROOT/bin:$PATH";
    fi
    # sccache compiler-output cache — used if installed. Append this
    # checkout's godot/ to SCCACHE_BASEDIRS so cache entries normalise
    # to a relative path and hits transfer across parallel godot trees
    # (your ~/.zshrc already lists ~/Desktop/godot and ~/Desktop/turboquant-godot;
    # this just appends ${WORLD_PWD}/${GODOT_DIR}).
    SCCACHE_FLAGS=""
    if command -v sccache >/dev/null 2>&1; then
        SCCACHE_FLAGS="c_compiler_launcher=sccache cpp_compiler_launcher=sccache"
        EXTRA_BASEDIR="${WORLD_PWD}/${GODOT_DIR}"
        if [ -n "${SCCACHE_BASEDIRS:-}" ]; then
            export SCCACHE_BASEDIRS="${SCCACHE_BASEDIRS}:${EXTRA_BASEDIR}"
        else
            export SCCACHE_BASEDIRS="${EXTRA_BASEDIR}"
        fi
        sccache --start-server >/dev/null 2>&1 || true
        sccache --zero-stats >/dev/null 2>&1 || true
    fi
    cd $GODOT_DIR
    case "{{platform}}" in
        macos)
            if [ "$(uname)" = "Darwin" ]; then
                unset OSXCROSS_ROOT
            else
                export PATH=${OSXCROSS_ROOT}/target/bin/:$PATH
            fi
            scons platform=macos \
                    arch={{arch}} \
                    werror=no \
                    compiledb=yes \
                    precision={{precision}} \
                    target={{target}} \
                    test=yes \
                    vulkan=no \
                    vulkan_sdk_path=$VULKAN_SDK_ROOT/MoltenVK/MoltenVK/static/MoltenVK.xcframework \
                    osxcross_sdk=darwin24 \
                    generate_bundle={{osx_bundle}} \
                    debug_symbols=yes \
                    separate_debug_symbols=yes \
                    ${SCCACHE_FLAGS} \
                    {{extra_options}}
            ;;
        windows)
            USE_MINGW="${USE_MINGW:-yes}"
            if [ "${USE_MINGW}" = "yes" ]; then
                WIN_TOOLCHAIN="use_llvm=yes use_mingw=yes"
            else
                WIN_TOOLCHAIN=""
            fi
            scons platform=windows \
                arch={{arch}} \
                werror=no \
                compiledb=yes \
                precision={{precision}} \
                target={{target}} \
                test=yes \
                ${WIN_TOOLCHAIN} \
                debug_symbols=yes \
                separate_debug_symbols=yes \
                ${SCCACHE_FLAGS} \
                {{extra_options}}
            ;;
        android)
            scons platform=android \
                    arch={{arch}} \
                    werror=no \
                    compiledb=yes \
                    precision={{precision}} \
                    target={{target}} \
                    test=yes \
                    ${SCCACHE_FLAGS} \
                    {{extra_options}} \
                    #debug_symbols=yes    # Editor build runs out of space in Github Runner
            ;;
        linuxbsd)
            DEBUG_SYMBOLS=""
            if [[ "$(just is-github-actions)" == "true" && "{{target}}" == "editor" ]]; then
                # Disable debug symbols for editor builds in CI to save disk space
                DEBUG_SYMBOLS="debug_symbols=no"
            else
                DEBUG_SYMBOLS="debug_symbols=yes separate_debug_symbols=yes"
            fi
            scons platform=linuxbsd \
                    arch={{arch}} \
                    werror=no \
                    compiledb=yes \
                    precision={{precision}} \
                    target={{target}} \
                    test=yes \
                    accesskit=no \
                    linuxbsd_speechd=no \
                    $DEBUG_SYMBOLS \
                    ${SCCACHE_FLAGS} \
                    {{extra_options}}
            ;;
        web)
            scons platform=web \
                    arch={{arch}} \
                    werror=no \
                    optimize=size_extra \
                    compiledb=yes \
                    precision={{precision}} \
                    target={{target}} \
                    test=yes \
                    dlink_enabled=yes \
                    debug_symbols=no \
                    disable_exceptions=yes \
                    ${SCCACHE_FLAGS} \
                    {{extra_options}}
            ;;
        ios)
            if [ "$(uname)" = "Darwin" ]; then
                unset OSXCROSS_ROOT
            else
                export PATH=${OSXCROSS_ROOT}/target/bin/:$PATH
            fi
            scons platform=ios \
                    arch={{arch}} \
                    werror=no \
                    compiledb=yes \
                    precision={{precision}} \
                    target={{target}} \
                    test=yes \
                    vulkan=no \
                    vulkan_sdk_path=$VULKAN_SDK_ROOT/MoltenVK/MoltenVK/static/MoltenVK.xcframework \
                    osxcross_sdk=darwin24 \
                    generate_bundle={{osx_bundle}} \
                    debug_symbols=yes \
                    separate_debug_symbols=yes \
                    ${SCCACHE_FLAGS} \
                    {{extra_options}}
            ;;
        *)
            echo "Unsupported platform: {{platform}}"
            exit 1
            ;;
    esac
    if [ -n "${SCCACHE_FLAGS}" ]; then
        sccache --show-stats || true
    fi
    just handle-special-cases {{platform}} {{target}}

    # Remove intermediate build files before copy
    rm -rf $WORLD_PWD/$GODOT_DIR/bin/obj

    # In Github runner copy editor as hardlink to save space
    if [[ "$(just is-github-actions)" == "true" ]]; then COPYSYM="-l"; else COPYSYM=""; fi

    if [[ "{{target}}" == "editor" ]]; then
        mkdir -p $WORLD_PWD/editors
        cp $COPYSYM -rf $WORLD_PWD/$GODOT_DIR/bin/* $WORLD_PWD/editors
    elif [[ "{{target}}" =~ template_* && \
            "{{platform}}" =~ ^(mac|i)os && \
            "{{osx_bundle}}" == "no" ]]; then
        # don't copy files to $WORLD_PWD/tpz
        true
    elif [[ "{{target}}" =~ template_* ]]; then
        mkdir -p $WORLD_PWD/tpz
        cp -rf $WORLD_PWD/$GODOT_DIR/bin/* $WORLD_PWD/tpz
    fi

build-platform-templates platform arch="auto" precision="double":
    # Bundle all on last command with osx_bundle
    just build-platform-target {{platform}} template_debug {{arch}} {{precision}} "no"
    just build-platform-target {{platform}} template_release {{arch}} {{precision}} "yes"

all-build-platform-target:
    #!/usr/bin/env bash
    parallel --ungroup --jobs 1 'just build-platform-target {1} {2}' \
    ::: windows linuxbsd macos android web \
    ::: editor template_debug template_release

handle-special-cases platform target:
    #!/usr/bin/env bash
    case "{{platform}}" in
        android)
            just handle-android {{target}} \
            ;;
        macos)
            just handle-macos {{target}} \
            ;;
    esac

handle-android target:
    #!/usr/bin/env bash
    just fetch-android-openxr-loader
    cd $GODOT_DIR
    if [ "{{target}}" = "editor" ]; then
        cd platform/android/java
        ./gradlew generateGodotEditor
        ./gradlew generateGodotHorizonOSEditor
        cd ../../..
        ls -l bin/android_editor_builds/
    elif [ "{{target}}" = "template_release" ] || [ "{{target}}" = "template_debug" ]; then
        cd platform/android/java
        ./gradlew generateGodotTemplates
        cd ../../..
        ls -l bin/
    fi

handle-macos target:
    #!/usr/bin/env bash
    cd $GODOT_DIR
    if [ "{{target}}" = "editor" ]; then
        chmod +x ./bin/*.app/Contents/MacOS/* || echo "Could not set execute permission on editor"
    fi

package-tpz folder tpzname versionpy precision="double":
    #!/usr/bin/env bash
    cd {{folder}}
    rm *.arm64.a || true  # Avoid Godot error on template import
    for file in *; do \
        filename=$( echo ${file} \
          | sed 's/\(godot.\|.double\|.template\|.llvm\|.wasm32\)//g' \
          | sed 's/linuxbsd/linux/;s/.console/_console/' \
          | sed 's/^web\(_debug\|_release\)\.\(dlink\)\(.*\)/web_\2\1\3/' \
          | sed 's/\(windows_[a-z]*\)\./\1_/' \
        ) \
        && echo -e "Renaming ${file} to \n ${filename}" \
        && mv ${file} ${filename}
    done
    cd ..
    cat {{versionpy}} | tr -d ' ' | tr -s '\n' ' ' \
      | sed -E 's/.*major=([0-9]).minor=([0-9]).*status=\"([a-z]*)\".*/\1.\2.\3/' \
      > {{folder}}/version.txt
    if [ "{{precision}}" = "double" ]; then
      echo ".double" >> {{folder}}/version.txt
    fi
    echo "Godot TPZ Version: $( cat {{folder}}/version.txt )"
    mkdir -p tpz_temp && mv {{folder}} tpz_temp/templates && cd tpz_temp \
      && zip -r ../{{tpzname}}.tpz templates && cd ..
    rm -r tpz_temp

# Print current sccache stats (works for both host and the most recent
# Docker build — the in-container sccache writes to a buildx cache volume
# whose stats are only viewable from within the build).
sccache-stats:
    #!/usr/bin/env bash
    if command -v sccache >/dev/null 2>&1; then
        sccache --show-stats
    else
        echo "sccache not installed; install with: brew install sccache (macOS) or cargo install sccache"
    fi

is-github-actions:
    #!/usr/bin/env bash
    if [[ "$CI" == "true" && "$GITHUB_ACTIONS" == "true" ]]; then
      echo "true"
    else
      echo "false"
    fi

# ── Docker images (consumed FROM by zone-baker / zone-server) ─────────
# The Dockerfile parameterises the engine binary via build-args. These
# recipes wire up `docker buildx` against the local godot/ checkout. Run
# `just fetch-godot` first; the build-context flag points buildx at the
# checkout without copying it into a tarball context.

# Build the Linux x86_64 editor image (used by zone-baker).
# Locally you can also build via the systemd quadlet:
#   systemctl --user start godot-editor-double-build  (see quadlets/*.build)
build-docker-editor tag="latest":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "${WORLD_PWD}"
    podman build \
        --build-arg TARGET=editor \
        --build-arg BINARY_NAME=godot.linuxbsd.editor.double.x86_64 \
        --build-context "godot-src=${WORLD_PWD}/${GODOT_DIR}" \
        --tag "${DOCKER_EDITOR_IMAGE}:{{tag}}" \
        --file Containerfile \
        .

# Build the Linux x86_64 template_release runtime image (used by zone-server).
build-docker-runtime tag="latest":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "${WORLD_PWD}"
    podman build \
        --build-arg TARGET=template_release \
        --build-arg BINARY_NAME=godot.linuxbsd.template_release.double.x86_64 \
        --build-context "godot-src=${WORLD_PWD}/${GODOT_DIR}" \
        --tag "${DOCKER_RUNTIME_IMAGE}:{{tag}}" \
        --file Containerfile \
        .

# Build both consumer-facing images.
build-docker tag="latest":
    just build-docker-editor {{tag}}
    just build-docker-runtime {{tag}}

# Push both images to ghcr.io. Run `podman login ghcr.io -u <user>` first.
push-docker tag="latest":
    podman push "${DOCKER_EDITOR_IMAGE}:{{tag}}"
    podman push "${DOCKER_RUNTIME_IMAGE}:{{tag}}"
