# Developer documentation

Build infrastructure for the
[`v-sekai-multiplayer-fabric/godot`](https://github.com/v-sekai-multiplayer-fabric/godot)
engine fork. One repo, one parameterised Dockerfile, one matrix workflow,
two output families.

## 1. Docker images (Linux x86_64)

`FROM`-able by the consumer repos that need a built engine binary.

| Image (`ghcr.io/v-sekai-multiplayer-fabric/…`) | Consumer | SCons target | Binary |
|---|---|---|---|
| `godot-editor-double` | [`zone-baker`](https://github.com/v-sekai-multiplayer-fabric/zone-baker) | `editor` | `godot.linuxbsd.editor.double.x86_64` |
| `zone-godot-runtime`  | [`zone-server`](https://github.com/v-sekai-multiplayer-fabric/zone-server) | `template_release` | `godot.linuxbsd.template_release.double.x86_64` |

Each consumer's `Dockerfile` just does
`FROM ghcr.io/v-sekai-multiplayer-fabric/<image>:latest` and copies `godot`
out — never recompiles the engine from source.

## 2. Player export templates (workflow artifacts)

`template_release` binaries for the desktop platforms a player ships on.
Uploaded as workflow artifacts per run (30-day retention) and named
`godot-template-<platform>-<ref>`.

| Platform | Arch | Runner | Binary |
|---|---|---|---|
| Linux | `x86_64` | `ubuntu-latest` | `godot.linuxbsd.template_release.double.x86_64` |
| Linux | `arm64`  | `ubuntu-22.04-arm` | `godot.linuxbsd.template_release.double.arm64` |
| Windows | `x86_64` | `windows-latest` | `godot.windows.template_release.double.x86_64.exe` |
| Windows | `arm64`  | `windows-11-arm` | `godot.windows.template_release.double.arm64.exe` |
| macOS   | `universal` (arm64 + x86_64) | `macos-14` | `godot.macos.template_release.double.universal` |

This coverage is intentionally wider than
[`V-Sekai-fire/multiplayer-fabric-build`](https://github.com/V-Sekai-fire/multiplayer-fabric-build),
which ships only `linux-x86_64` / `windows-x86_64` / `macos-arm64+x86_64`
on the desktop matrix — the `arm64` Linux and Windows runtimes are added
here for player distribution to those platforms.

## Engine pin

All jobs build from a **hard-coded tag** of
[`v-sekai-multiplayer-fabric/godot`](https://github.com/v-sekai-multiplayer-fabric/godot/tags)
— not a moving branch, and not a submodule / `git-subrepo`. The tag is
declared once in `.github/workflows/build.yml`:

```yaml
env:
  GODOT_PINNED_REF: v2026.05.21.0007-multiplayer-fabric
```

To bump the engine version: edit that one value and merge. Engine source
is freshly cloned at the pinned ref on every CI run via `actions/checkout`,
so no in-tree copy ever drifts. All build configuration stays the same:
`precision=double accesskit=no linuxbsd_speechd=no` for Linux, the
platform-appropriate variants for Windows / macOS.

## Triggers

- **Manual** (`workflow_dispatch`) — override the pin for a test build:
  `gh workflow run build.yml --repo v-sekai-multiplayer-fabric/godot-images -F godot_ref=<branch-or-sha>`
  (omit `godot_ref` to use the pinned tag).
- **Weekly cron** (Mondays 02:00 UTC) — rebuilds the pinned tag so any
  toolchain / base-image drift is caught early.
- **`repository_dispatch` event `engine-updated`** — for when the engine
  repo wants to fan out a fresh build at a specific ref. Trigger from a
  workflow there:
  ```yaml
  - uses: peter-evans/repository-dispatch@v3
    with:
      token: ${{ secrets.GODOT_IMAGES_TRIGGER_TOKEN }}   # PAT with workflow:write on this repo
      repository: v-sekai-multiplayer-fabric/godot-images
      event-type: engine-updated
      client-payload: '{"godot_ref": "${{ github.ref_name }}"}'
  ```

## Why a separate repo

The engine build is a slow (~1h on a free runner per matrix cell),
wide-radius operation — keeping it out of `zone-baker` and `zone-server`
means a doc-tweak in those consumer repos doesn't fight for a runner slot
with a 1h compile. It also removes the duplicated `docker/godot-binary/`
and `docker/godot-zone/` Dockerfiles that used to live in each consumer
(~80 lines of near-identical configuration each).

## Layout

```
Dockerfile             parameterised by TARGET + BINARY_NAME build-args
justfile               build recipes (cross-compile setup + scons dispatch
                       per platform). CI and local developers call the
                       same recipes — see "Building locally" below.
.github/workflows/
  build.yml            two matrices:
                         build-docker   {editor, runtime} → ghcr.io
                         build-template {linux,windows × x86_64,arm64; macos universal} → artifacts
```

## Building locally

All build flags live in `justfile`. The CI workflow uses native runners
for each desktop platform, but the same recipes also work cross-compiled
from a single Linux host (the multiplayer-fabric-build style), so engineers
can build any platform from one workstation.

```sh
# clone engine source side-by-side
git clone https://github.com/v-sekai-multiplayer-fabric/godot.git godot
git -C godot checkout v2026.05.21.0106-multiplayer-fabric  # or whatever GODOT_PINNED_REF is

# native build on your host
just install_packages                                       # Linux deps
just build-platform-target linuxbsd template_release x86_64 double

# windows from Linux via llvm-mingw
just install_packages
just fetch-llvm-mingw
just setup-d3d12
just build-platform-target windows template_release x86_64 double

# windows on a native Windows host (MSVC)
USE_MINGW=no just build-platform-target windows template_release x86_64 double

# macos / ios from Linux via osxcross
just build-osxcross
just fetch-vulkan-sdk
just build-platform-target macos template_release universal double
just build-platform-target ios   template_release arm64     double

# android / web also covered
just fetch-openjdk && just setup-android-sdk
just build-platform-target android template_release arm64 double

just setup-emscripten
just build-platform-target web template_release wasm32 double
```

Binaries land in `godot/bin/`. The recipe also copies into `editors/` (for
`target=editor`) or `tpz/` (for `target=template_*`) at the repo root, and
`just package-tpz tpz <name> godot/version.py double` zips them into a
Godot-loadable `.tpz` template pack.

## Cache + retention

- **Docker (Linux)**: `cache-to: type=gha,mode=max,scope=<matrix.name>`
  separates editor and runtime caches so each variant keeps its own
  incremental compile state. GHA cache evicts after 7d of inactivity per
  scope.
- **Native (desktop templates)**: SCons object cache stored under
  `actions/cache` keyed by `<platform>-<arch>-<godot-ref>` so a re-run at
  the same pin is incremental.
- **Image retention**: GHCR is package-level — every pushed
  `:<sanitized-ref>` and `:<sha>` tag stays alongside `:latest` so
  consumers can pin to a known-good engine via image digest if needed.
- **Artifact retention**: workflow artifacts expire after 30 days; pin a
  consumer to a known-good `GODOT_PINNED_REF` and re-run the workflow to
  rematerialise.
