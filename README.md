# v-sekai-multiplayer-fabric/godot-images

Single-source-of-truth Docker images for the
[`v-sekai-multiplayer-fabric/godot`](https://github.com/v-sekai-multiplayer-fabric/godot)
engine fork. One repo, one parameterised Dockerfile, one matrix workflow,
two output images:

| Image (ghcr.io/v-sekai-multiplayer-fabric/…) | Consumer | SCons target | Binary |
|---|---|---|---|
| `godot-editor-double` | [`zone-baker`](https://github.com/v-sekai-multiplayer-fabric/zone-baker) | `editor` | `godot.linuxbsd.editor.double.x86_64` |
| `zone-godot-runtime`  | [`zone-server`](https://github.com/v-sekai-multiplayer-fabric/zone-server) | `template_release` | `godot.linuxbsd.template_release.double.x86_64` |

Both build from `v-sekai-multiplayer-fabric/godot @ feat/assets` (overridable
on manual dispatch) with `precision=double accesskit=no linuxbsd_speechd=no`.
Each consumer's `Dockerfile` just does
`FROM ghcr.io/v-sekai-multiplayer-fabric/<image>:latest` and copies `godot`
out — never recompiles the engine from source.

## Triggers

- **Manual** (`workflow_dispatch`) — handy for testing a feature branch:
  `gh workflow run build.yml --repo v-sekai-multiplayer-fabric/godot-images -F godot_ref=<branch-or-sha>`
- **Weekly cron** (Mondays 02:00 UTC) — picks up engine drift automatically.
- **`repository_dispatch` event `engine-updated`** — for when the engine
  repo wants to fan out a fresh build. Trigger from a workflow there:
  ```yaml
  - uses: peter-evans/repository-dispatch@v3
    with:
      token: ${{ secrets.GODOT_IMAGES_TRIGGER_TOKEN }}   # PAT with workflow:write on this repo
      repository: v-sekai-multiplayer-fabric/godot-images
      event-type: engine-updated
      client-payload: '{"godot_ref": "${{ github.ref_name }}"}'
  ```

## Why a separate repo

The engine build is a slow (~1h on free runners), wide-radius operation —
keeping it out of `zone-baker` and `zone-server` means a doc-tweak in those
consumer repos doesn't fight for a runner slot with a 1h compile. It also
removes the duplicated `docker/godot-binary/` and `docker/godot-zone/`
Dockerfiles that used to live in each consumer (~80 lines of near-identical
configuration each).

## Layout

```
Dockerfile             parameterised by TARGET + BINARY_NAME build-args
.github/workflows/
  build.yml            matrix: {editor, runtime} × push to ghcr
```

## Cache + retention

The `cache-to: type=gha,mode=max,scope=<matrix.name>` separates the
editor and runtime caches so each variant keeps its own incremental
compile state. GHA cache evicts after 7d of inactivity per scope.

Image retention on ghcr is package-level — the latest pushed `:<sha>` tag
stays alongside `:latest` so consumers can pin to a known-good engine SHA
via `--build-arg` if needed.
