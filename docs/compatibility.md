# Compatibility matrix

Three packages, three different reusability stories.

## ziti-router -- universal

Static Go binary built with `CGO_ENABLED=0` from openziti/ziti source. Zero dynamic dependencies.
Runs on any aarch64-musl or x86_64-musl OpenWRT 23.05 or later, vanilla or QSDK.

## luci-app-ziti -- universal (arch-independent)

Plain JS views + UCI + rpcd shell backend. `Architecture: all`. Requires `luci-base` 23.05 or
later (older LuCI lacks the JS-view runtime).

## ziti-edge-tunnel + llhttp9 -- arch-tag locked

C package, dynamically linked. `opkg` matches packages to devices by exact architecture *label*.
The same binary will run on any compatible aarch64 chip, but `opkg` refuses to install when the
tag does not match what `opkg print-architecture` reports.

### Tags shipped today

| Arch tag | Devices | Source |
|---|---|---|
| `aarch64_cortex-a53` | mvebu Cortex-A53 (GL-MV1000, NanoPi R2S, FriendlyELEC NEO3, ESPRESSObin, MACCHIATObin) | Native build |
| `aarch64_cortex-a53_neon-vfpv4` | GL.iNet QSDK (GL-BE3600, GL-MT6000, GL-AXT1800) | Repacked control tag, same binary |
| `x86_64` | OpenWRT x86_64 routers and VMs | Native build |

### Could-work, not shipped yet

Same aarch64 family, ARMv8-A guarantees NEON, but our published feed has no per-tag subdir for them:

- `aarch64_generic`
- `aarch64_cortex-a72` (Raspberry Pi 4-class, ROCK Pi 4)
- `aarch64_cortex-a76` (Raspberry Pi 5, NanoPi R6S)

To add: extend `REPACK_TO_ARCH` in `.github/workflows/publish-feed.yml`. No rebuild required;
just rewrites the `Architecture:` line in the `.ipk` control file.

### Needs a separate build

Different ISA -- requires a per-target SDK and a full rebuild:

- 32-bit ARM (`arm_cortex-a7`, `arm_cortex-a9`, `arm_cortex-a15`)
- MIPS, MIPSEL (`mips_24kc`, `mipsel_24kc`)
- riscv64

To add: extend the target table in `tools/build-sdk.sh` and the matrix in
`.github/workflows/publish-feed.yml`. Note: ziti-router on flash-constrained 32-bit devices is
borderline (the binary is ~19 MB).

## OpenWRT release-line compatibility

`ziti-edge-tunnel` dynamically links libuv1, libopenssl3, zlib, libjson-c5, libsodium,
libprotobuf-c, libpcap1, libatomic1. ABI compatibility verified against:

- OpenWRT 23.05.5 (the build target)
- GL.iNet QSDK v12.5 (close-to-23.05.5 userspace; live test on GL-BE3600 passed)

Likely compatible (same release line preserves ABI within a major):

- OpenWRT 23.05.0 through 23.05.5

Likely NOT compatible:

- 22.x and earlier (libopenssl 1.1 vs 3.x)
- 24.x (untested; libopenssl bumped to 3.2)
