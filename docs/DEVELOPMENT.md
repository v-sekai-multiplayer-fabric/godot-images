# Developer documentation

Local-first build infrastructure for the
[`v-sekai-multiplayer-fabric/godot`](https://github.com/v-sekai-multiplayer-fabric/godot)
engine fork. There is no CI workflow — every output of this repo is
produced by running a [`just`](https://github.com/casey/just) recipe on a
developer machine. The recipes cross-compile from Linux to every
supported platform and also build natively where simpler.

## Outputs

### Player export templates (developer artifacts)

`template_release` binaries land in `godot/bin/` after running the
appropriate `build-platform-target` recipe. Suggested distribution:
attach to a GitHub release on this repo manually, or zip into a `.tpz`
template pack with `just package-tpz`.

| Platform | Arch | Recipe (Linux host) | Binary in `godot/bin/` |
|---|---|---|---|
| Linux   | `x86_64` | `just install_packages && just build-platform-target linuxbsd template_release x86_64 double` | `godot.linuxbsd.template_release.double.x86_64` |
| Linux   | `arm64`  | `just install_packages && just setup-arm64 && just build-platform-target linuxbsd template_release arm64 double` | `godot.linuxbsd.template_release.double.arm64` |
| Windows | `x86_64` | `just install_packages && just fetch-llvm-mingw && just setup-d3d12 && just build-platform-target windows template_release x86_64 double` | `godot.windows.template_release.double.x86_64.exe` |
| Windows | `arm64`  | `just install_packages && just fetch-llvm-mingw && just setup-d3d12 && just build-platform-target windows template_release arm64 double` | `godot.windows.template_release.double.arm64.exe` |
| Windows | `x86_64` (native MSVC) | `USE_MINGW=no just build-platform-target windows template_release x86_64 double` (run on a Windows host) | same as above |
| macOS   | `universal` (arm64 + x86_64) | `just build-osxcross && just fetch-vulkan-sdk && just build-platform-target macos template_release universal double` (or native on macOS) | `godot.macos.template_release.double.universal` |
| iOS     | `arm64`  | `just build-osxcross && just fetch-vulkan-sdk && just build-platform-target ios template_release arm64 double` | `godot.ios.template_release.double.arm64` |
| Android | `arm64`  | `just fetch-openjdk && just setup-android-sdk && just build-platform-target android template_release arm64 double` | `godot.android.template_release.double.arm64` |
| Android | `x86_64` | (as above, `arch=x86_64`) | `godot.android.template_release.double.x86_64` |
| Web     | `wasm32` | `just setup-emscripten && just build-platform-target web template_release wasm32 double` | `godot.web.template_release.double.wasm32.zip` |

Coverage is intentionally wider than
[`V-Sekai-fire/multiplayer-fabric-build`](https://github.com/V-Sekai-fire/multiplayer-fabric-build),
which ships only `linux-x86_64`, `windows-x86_64`, and macOS arm64+x86_64
on the desktop matrix.

### Docker images (consumer-facing)

`FROM`-able by [`zone-baker`](https://github.com/v-sekai-multiplayer-fabric/zone-baker)
and [`zone-server`](https://github.com/v-sekai-multiplayer-fabric/zone-server).
Build and push from any Linux host with Docker (or Docker Desktop):

```sh
just fetch-godot
just build-docker            # editor + runtime
docker login ghcr.io -u <github-user>
just push-docker
```

| Image (`ghcr.io/v-sekai-multiplayer-fabric/…`) | Consumer | SCons target | Binary |
|---|---|---|---|
| `godot-editor-double` | [`zone-baker`](https://github.com/v-sekai-multiplayer-fabric/zone-baker) | `editor` | `godot.linuxbsd.editor.double.x86_64` |
| `zone-godot-runtime`  | [`zone-server`](https://github.com/v-sekai-multiplayer-fabric/zone-server) | `template_release` | `godot.linuxbsd.template_release.double.x86_64` |

Each consumer's `Dockerfile` does `FROM ghcr.io/v-sekai-multiplayer-fabric/<image>:latest`
and copies `godot` out — never recompiles the engine from source.

## Engine pin

All recipes default to a hard-coded tag of
[`v-sekai-multiplayer-fabric/godot`](https://github.com/v-sekai-multiplayer-fabric/godot/tags)
— not a moving branch, and not a submodule / `git-subrepo`. The tag lives
once at the top of `justfile`:

```just
export GODOT_PINNED_REF := "v2026.05.21.0106-multiplayer-fabric"
```

To bump the engine version: edit that line and re-run `just fetch-godot`.
The fork is freshly fetched on every `fetch-godot` invocation, so no
in-tree copy ever drifts. Override for an ad-hoc build with
`just fetch-godot <branch-or-sha>`.

## CI

There is a manual GitHub Actions workflow at
[`.github/workflows/build.yml`](../.github/workflows/build.yml) that just
calls `just build-docker-*` on `ubuntu-latest` and pushes to ghcr.io.
Triggers: `workflow_dispatch`, weekly Monday cron, and the
`engine-updated` `repository_dispatch` event. There is intentionally no
`push:` trigger — engine compiles are too slow to run on every doc tweak.

CI uses the same justfile and Dockerfile as a local build; the only
difference is that the workflow injects the Tigris secrets as `env:`
which the justfile then forwards via `--build-arg` so the in-Docker
sccache reads/writes the shared Tigris bucket. Cache entries from a
developer's `just build-docker` accumulate in the same pool as CI runs.

## sccache pool

A [Tigris](https://www.tigrisdata.com/) (Fly.io) S3-compatible bucket
named `godot-images-sccache` backs sccache for both CI and developer
machines. Provisioned with:

```sh
fly storage create --name godot-images-sccache --org personal
```

The credentials live in two places:

- **CI**: as repo-level GitHub Actions secrets on this repo:
  `SCCACHE_BUCKET`, `SCCACHE_ENDPOINT`, `SCCACHE_REGION`,
  `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`.
- **Local**: `~/.sccache-tigris.env` (mode `0600`, never committed).
  Source it to switch your host sccache from local-disk to the shared
  bucket:

  ```sh
  source ~/.sccache-tigris.env
  just                  # default = fetch-godot + build-docker
  sccache --show-stats  # see hits / misses against Tigris
  ```

Cache entries are keyed per-compiler (preprocessed input + flags +
compiler hash), so the bucket simultaneously holds macOS clang, Linux
gcc, MinGW, and Emscripten entries without collision — each platform
pulls only the entries that match its own compiler.

## Engine compile cache layering

Two complementary caches back every scons invocation:

1. **sccache** — compiler-output cache. Shared across the editor and
   runtime builds (large overlap because most of `core/` and `scene/`
   compile identically across `target=editor` vs `target=template_release`).
   Shared across machines via the Tigris bucket.
2. **SCons file cache** (`cache_path=...`) — avoids re-running build-graph
   nodes for unchanged inputs. Lives in `godot/.scons_cache` on host
   builds, and in a buildx cache mount inside Docker.

## Layout

```
Dockerfile             parameterised by TARGET + BINARY_NAME build-args
                       and the SCCACHE_* env vars; invoked by
                       `just build-docker-{editor,runtime}`
justfile               every build recipe (cross-compile setup + scons
                       dispatch + docker build/push); forwards sccache
                       creds into buildx via _sccache_buildargs
.github/workflows/
  build.yml            manual + weekly CI that calls `just build-docker-*`
                       with the same justfile, secrets injected as env
```

## Toolchain caches

`osxcross`, `mingw`, `vulkan_sdk`, `emsdk`, `android_sdk`, and
`aarch64-godot-linux-gnu_sdk-buildroot` are cached in the working
directory by their respective `fetch-*` / `setup-*` recipes and reused
on subsequent runs. They're all listed in `.gitignore`.
