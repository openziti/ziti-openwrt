# tools/ -- openwrt-openziti SDK build harness

Builds `.ipk` packages for openwrt-openziti by running the OpenWRT 23.05 SDK
inside Docker. All build logic lives in PowerShell scripts so the same
commands run locally and from CI.

## Prerequisites

- Windows host with PowerShell 5.1+ (or `pwsh` 7+).
- Docker Desktop (or any Linux host with Docker) on PATH.
- Network access to `downloads.openwrt.org` for SDK tarballs.

The SDK image installs: `build-essential libncurses-dev zlib1g-dev gawk git
gettext libssl-dev xsltproc rsync wget unzip python3 file` (plus
`swig`, `time`, `ca-certificates`).

## Single-target build

```powershell
# Validate the harness end-to-end with the stub package:
./tools/build-sdk.ps1 -Target aarch64_cortex-a53 -Package _stub

# Build a real package once other streams land:
./tools/build-sdk.ps1 -Target x86_64 -Package ziti-edge-tunnel
```

Override the SDK URL when the default mapping does not fit (e.g. IPQ5332 /
qualcommax requires 23.05-SNAPSHOT, which is not in the 23.05.5 release tree):

```powershell
./tools/build-sdk.ps1 -Target aarch64_cortex-a53 -SdkUrl `
  "https://downloads.openwrt.org/snapshots/targets/qualcommax/ipq53xx/openwrt-sdk-qualcommax-ipq53xx_gcc-13.3.0_musl.Linux-x86_64.tar.xz"
```

Re-use a previously built image:

```powershell
./tools/build-sdk.ps1 -Target x86_64 -Package _stub -SkipBuild
```

## Targeting the GL-BE3600 / IPQ5332

The GL-iNet GL-BE3600 uses Qualcomm IPQ5332, which lives in the
`qualcommax/ipq53xx` subtarget. This subtarget is only present in OpenWRT
SNAPSHOT (not in 23.05.x stable), so the build pulls a snapshots SDK:

```powershell
./tools/build-sdk.ps1 -Target aarch64_cortex-a53_ipq53xx -Package ziti-edge-tunnel
```

The `aarch64_cortex-a53_ipq53xx` target is in the script's
`SnapshotOnlyTargets` list, so `-Snapshot` is implied automatically and the
URL derivation switches to:

```
https://downloads.openwrt.org/snapshots/targets/qualcommax/ipq53xx/openwrt-sdk-qualcommax-ipq53xx_gcc-<ver>_musl.Linux-x86_64.tar.zst
```

SNAPSHOT URLs are not stable -- the toolchain version (`gcc-<ver>`) embedded
in the filename rolls forward whenever upstream OpenWRT bumps gcc. If the
default URL 404s, browse
<https://downloads.openwrt.org/snapshots/targets/qualcommax/ipq53xx/> for the
current `openwrt-sdk-*.tar.zst` filename and either:

1. Pass it explicitly:

   ```powershell
   ./tools/build-sdk.ps1 -Target aarch64_cortex-a53_ipq53xx -Package ziti-edge-tunnel `
     -SdkUrl "https://downloads.openwrt.org/snapshots/targets/qualcommax/ipq53xx/openwrt-sdk-qualcommax-ipq53xx_gcc-<NEW>_musl.Linux-x86_64.tar.zst"
   ```

2. Or bump the `$snapGcc` default in `tools/build-sdk.ps1`'s `Get-SdkUrl`.

You can also force snapshots for any other target (e.g. to pick up a fix
that has not landed in 23.05.x yet) with `-Snapshot`:

```powershell
./tools/build-sdk.ps1 -Target x86_64 -Package ziti-edge-tunnel -Snapshot
```

## Matrix build

```powershell
./tools/build-matrix.ps1 -Package _stub
```

Defaults to `aarch64_cortex-a53, x86_64, arm_cortex-a7, mipsel_24kc, mips_24kc`.
Continues on failure; writes per-target results to `build/matrix-result.json`.

## Artifacts

`.ipk` files land in `build/<target>/`. The `build/` directory is gitignored.
`build/matrix-result.json` records pass/fail + duration for each matrix run.

## Publishing an opkg feed

Once `.ipk` files exist under `build/<target>/`, assemble them into an opkg
feed (Packages, Packages.gz, optional usign-signed Packages.sig):

```powershell
# Unsigned feed (warning emitted; fine for local testing).
./tools/publish-feed.ps1

# Signed feed for a real release.
./tools/publish-feed.ps1 `
    -SigningKey C:\keys\openziti-feed.sec `
    -BaseUrl https://your-org.github.io/openwrt-openziti
```

Output: `build\feed\<target>\Packages[.gz|.sig]` plus a top-level
`build\feed\feed-info.json`. Sanity-check locally:

```powershell
./tools/feed-server.ps1     # http://localhost:8181/  -- DEV ONLY, no HTTPS
```

Hosting + GL.iNet device install instructions live in
`docs/feed-hosting.md`. The `.ipk` parsing and `usign` invocation run inside
a small alpine container built from `tools/Dockerfile.feed`, so the host
needs only Docker (already required for `build-sdk.ps1`) and PowerShell.

## Known gotchas

- The OpenWRT SDK refuses to build as root; the image runs as user `builder`.
- `feeds.conf` is rewritten inside the container to prepend
  `src-link local /feed`; the host `package/` tree is bind-mounted read-only.
- `arm_cortex-a7` defaults to the `mvebu/cortexa9` SDK (a Cortex-A7-class
  toolchain). For ipq40xx-class boards pass
  `-Target arm_cortex-a7_neon-vfpv4` (mapped to `ipq40xx/generic`) or
  override `-SdkUrl`.
- The IPQ5332 / GL-BE3600 target is only in 23.05-SNAPSHOT, not 23.05.5
  stable. Use `-SdkUrl` to point at the snapshots tree.
- Docker Desktop on Windows: ensure the repo drive is shared in
  Settings -> Resources -> File Sharing so bind mounts work.
- First image build downloads ~150 MB SDK tarball + ~400 MB apt packages.
