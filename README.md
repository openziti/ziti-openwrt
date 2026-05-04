# ziti-openwrt

[OpenZiti](https://openziti.io) packaged for OpenWRT. Three components:

- `ziti-edge-tunnel` (C tunneler) + `llhttp9` runtime dep
- `ziti-router` (Go router)
- `luci-app-ziti` (web UI)

## Compatibility

| Package | Where it runs |
|---|---|
| `ziti-router` | Any aarch64-musl or x86_64-musl OpenWRT 23.05+ (static binary, no deps) |
| `luci-app-ziti` | Any OpenWRT 23.05+ with luci-base (architecture-independent) |
| `ziti-edge-tunnel` + `llhttp9` | `aarch64_cortex-a53`, `aarch64_cortex-a53_neon-vfpv4` (GL.iNet QSDK), `x86_64` |

See [`docs/compatibility.md`](docs/compatibility.md) for the full matrix and how to add new targets.

## Install

End users: see [`docs/installing.md`](docs/installing.md). GL.iNet QSDK users: [`docs/install-gl-inet.md`](docs/install-gl-inet.md).

## Build

```bash
bash tools/build-sdk.sh -p ziti-edge-tunnel
```

Builds via the OpenWRT 23.05.5 SDK in Docker. Output is a per-target `.ipk` under `build/<target>/`.
For ziti-router, run `bash tools/build-ziti-router.sh` first to produce the static Go binary.

## Publish a signed feed

The repo includes a GitHub Actions workflow (`.github/workflows/publish-feed.yml`) that builds
all packages, signs the feed with usign, and deploys to GitHub Pages. See
[`docs/feed-publishing-setup.md`](docs/feed-publishing-setup.md) for the one-time maintainer setup.

## Layout

```
.github/workflows/   CI: build matrix, sign, deploy
package/             opkg packages
  ziti-edge-tunnel/  C, dynamically linked
  ziti-router/       Go, statically linked
  luci-app-ziti/     LuCI app, arch-independent
  llhttp/            ZET runtime dep
  stc/               ZET build dep
tools/               build, repack, publish (bash + PowerShell wrappers)
docs/                guides, design notes, run reports
```

## License

Apache-2.0. Same as upstream OpenZiti.
