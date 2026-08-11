# Router compatibility matrix

A durable reference for anyone who wants to install OpenZiti on their own OpenWRT router from this project's public
signed opkg feed. It maps the architectures the feed publishes to real router models, states the OpenWRT version
requirements, and is honest about what is verified versus experimental versus not built at all.

This project ships three components:

- **ziti-edge-tunnel (ZET)** -- the C tunneler, the user-facing dataplane. This is the piece the full-tunnel travel
  router runs as its gateway.
- **ziti-router** -- the Go router/edge-router (a large static binary).
- **luci-app-ziti** -- the LuCI web UI for ZET.

The reference build for this project is the **GL.iNet Slate 7 (GL-BE3600, Qualcomm IPQ5332, aarch64)** used as a
full-tunnel travel router. That device is verified live. The rest of this document generalizes from it.

## What you need

For the basic case (put an OpenWRT router on the OpenZiti overlay), you need exactly one thing:

- **A supported OpenWRT router** from the matrix below, running an OpenWRT 23.05.x-based firmware (GL.iNet firmware
  4.5 or later qualifies -- it is 23.05-based).

That is all. **No special hardware, no dongle, no proprietary appliance.** OpenZiti is software; a stock supported
router is enough. The public feed installs the packages straight over HTTPS from GitHub Pages, so you do not even need
a build host.

For the **full-tunnel travel-router use case** (non-Ziti client devices behind your router's wifi egress from a remote
location, appear-to-be-elsewhere), you additionally need one **exit endpoint** on the OpenZiti overlay that hosts the
egress service. That exit is not special equipment either -- it is any always-on machine you already own running
OpenZiti in a hosting role:

- **ZET (`ziti-edge-tunnel`) in `run-host` mode** on a Linux VPS, a home server, a mini PC, or a second router. A cloud
  Linux VPS is the simplest exit because `host.v1` forward-to-original-destination self-NATs (the hosting tunneler opens
  its own outbound sockets), so the exit needs no `ip_forward`, no masquerade, no `New-NetNat`.
- **A ziti-router in `host` mode**, which is equivalent to ZET `run-host` for the egress side.
- **An existing OpenZiti edge router** on your network, authorized to bind the egress service.

You also need an **OpenZiti controller** to enroll identities against (self-hosted or a hosted OpenZiti network). The
travel router itself needs no inbound ports and no public IP -- it dials out to the overlay.

See `docs/full-tunnel-travel-router.md` for the end-to-end runbook and `docs/travel-router-buildlog.md` for the
decision record (why ZET's TUN+lwIP datapath is used for the client gateway rather than the ziti-router tproxy path).

## The matrix

The public feed lives at **https://openziti.github.io/ziti-openwrt** with a per-architecture subdirectory. Find your
device's tag by SSHing in and running `opkg print-architecture | awk '{print $2}'` -- use the most specific tag it
reports (usually the last line).

| Arch tag | Example routers (GL.iNet / generic) | OpenWRT line | ZET | ziti-router | luci-app-ziti | Flash / RAM guidance | Notes |
|---|---|---|---|---|---|---|---|
| `aarch64_cortex-a53` | Generic mvebu Cortex-A53 SBCs and routers: NanoPi R2S, FriendlyELEC NEO3, ESPRESSObin, MACCHIATObin, GL-MV1000 | 23.05.x | Yes | Yes | Yes (`all`) | ZET fine on 16 MB flash / 128 MB RAM. ziti-router wants 128 MB+ flash (large static Go binary). | Native build. The canonical vanilla-OpenWRT aarch64 tag. |
| `aarch64_cortex-a53_neon-vfpv4` | GL.iNet QSDK: **GL-BE3600 (Slate 7)**, GL-MT6000 (Flint 2), GL-AXT1800 (Slate AX), GL-MT3000 (Beryl AX), GL-AX1800 (Flint) | 23.05-SNAPSHOT (GL QSDK v12.5, fw 4.5+) | Yes | Yes | Yes (`all`) | Slate 7 has 512 MB NAND / 1 GB RAM -- roomy. Older QSDK boxes vary; ZET is comfortable, router needs headroom. | Server-side repack: same aarch64 binary as the row above, control tag rewritten. `_neon-vfpv4` is vestigial 32-bit naming; ISA is identical. No local repack needed from the feed. |
| `x86_64` | Any x86_64 OpenWRT box, VM, mini PC, APU2/APU4, virtualized router; QEMU smoke target | 23.05.x | Yes | Yes | Yes (`all`) | Disk-backed; both components fit trivially. | Native build. Also the CI QEMU install-smoke target. |
| `arm_cortex-a7_neon-vfpv4` | GL.iNet IPQ4018/4019: GL-B1300, GL-AP1300, GL-S1300 | 23.05.x (ipq40xx) | Yes (experimental) | **No** | Yes (`all`) | Typically 16-32 MB flash / 256 MB RAM. ZET + LuCI fit; router would not. | **Experimental**: build wired up (CI `continue-on-error`), not validated on hardware. Feed carries 3 packages (no router). |
| `mipsel_24kc` | GL.iNet MT7621: GL-MT1300 (Beryl), GL-AR750S (Slate), GL-X750 (Spitz), GL-AR300M (newer rev) | 23.05.x (ramips/mt7621) | Yes (experimental) | **No** | Yes (`all`) | Small: often 16-32 MB flash / 128-256 MB RAM. ZET + LuCI only; watch free flash. | **Experimental**: wired up, not validated. Feed carries 3 packages (no router). |

Notes on the router column: `ziti-router` is restricted to aarch64 + x86_64 via `DEPENDS:=@(aarch64||x86_64)`. The
self-built cross-compile flow only produces arm64 and amd64 static binaries, and the binary is too large for the
typical 16 MB flash budget on the 32-bit boxes anyway (roughly 19 MB unpacked per this repo's own measurement; plan for
tens of MB of install footprint, so a device with 128 MB+ flash). ZET is a dynamically-linked musl binary and is much
lighter; it and its shared-library deps install comfortably on a 16 MB device.

### Could work but not published

Same aarch64 (ARMv8-A) family, so the binary would run, but the feed has no per-tag subdirectory for them yet:

- `aarch64_generic`
- `aarch64_cortex-a72` (Raspberry Pi 4-class, ROCK Pi 4)
- `aarch64_cortex-a76` (Raspberry Pi 5, NanoPi R6S)

Adding these needs no rebuild -- it is a control-tag repack rule (extend `REPACK_TO_ARCH` in the publish workflow). If
you have one of these devices and want it added, open an issue with your `opkg print-architecture` output.

### Needs a separate build (not shipped)

Different ISA, requires a per-target SDK and a full rebuild: 32-bit ARM other than the a7 above (`arm_cortex-a9`,
`arm_cortex-a15`), big-endian MIPS (`mips_24kc`), riscv64. On flash-constrained 32-bit devices, ziti-router remains
out of reach regardless.

## OpenWRT version support

**Target line: 23.05.x.** ZET is built against the OpenWRT 23.05.5 SDK and dynamically links a specific set of shared
libraries: `libuv1`, `libopenssl3`, `zlib`, `libjson-c5`, `libsodium`, `libprotobuf-c`, `libpcap1`, `libatomic1`. opkg
resolves those from your device's own feeds at install time, so the device's libraries must be ABI-compatible with what
ZET was linked against.

Verified compatible:

- **OpenWRT 23.05.0 through 23.05.5** (same release line preserves ABI within the major).
- **GL.iNet QSDK v12.5** (a close-to-23.05.5 userspace; the GL-BE3600 live test passed -- ZET loaded and ran cleanly
  against the QSDK builds of libuv1, libopenssl3, zlib, libjson-c5, libsodium 1.0.18, libprotobuf-c 1.4.1, libpcap1,
  libatomic1).

Likely NOT compatible:

- **22.x and earlier**: ships **libopenssl 1.1**, a different SONAME/ABI than the libopenssl 3.x ZET is linked against.
  On GL.iNet, this maps to firmware **4.4 and below** (OpenWRT 21.02 / 22.03). ZET will fail to resolve/load. Not
  supported.
- **24.x**: libopenssl was bumped to **3.2**; untested here and not published. It may work if the other SONAMEs held,
  but it is unverified.

What supporting 22.x or 24.x would take: rebuild ZET (and llhttp9) against that release line's SDK so the packages link
the matching library SONAMEs, then publish a new per-line feed. `ziti-router` is unaffected by this -- it is a fully
static `CGO_ENABLED=0` Go binary with zero shared-library dependencies, so it runs on any aarch64-musl or x86_64-musl
OpenWRT 23.05 or later regardless of the libopenssl situation. `luci-app-ziti` is `Architecture: all` and only needs
`luci-base` from 23.05 or later (older LuCI lacks the JS-view runtime).

## The easy-install path (public feed)

The maintainers publish an already-signed, already-repacked feed. On the device, install the signing key once, add the
subdirectory that matches your arch, then install. Example for a GL.iNet QSDK device (`aarch64_cortex-a53_neon-vfpv4`):

```sh
mkdir -p /etc/opkg/keys
curl -fsSL https://openziti.github.io/ziti-openwrt/pub.key -o /tmp/pub.key
KEYID=$(usign -F -p /tmp/pub.key)
mv /tmp/pub.key /etc/opkg/keys/$KEYID

echo "src/gz openziti https://openziti.github.io/ziti-openwrt/aarch64_cortex-a53_neon-vfpv4" \
    >> /etc/opkg/customfeeds.conf
opkg update
opkg install ziti-edge-tunnel luci-app-ziti ziti-router
```

For other arches, swap only the subdirectory in the `src/gz` line:

| Your device reports | Use this feed URL |
|---|---|
| `aarch64_cortex-a53` | `https://openziti.github.io/ziti-openwrt/aarch64_cortex-a53` |
| `aarch64_cortex-a53_neon-vfpv4` | `https://openziti.github.io/ziti-openwrt/aarch64_cortex-a53_neon-vfpv4` |
| `x86_64` | `https://openziti.github.io/ziti-openwrt/x86_64` |
| `arm_cortex-a7_neon-vfpv4` | `https://openziti.github.io/ziti-openwrt/arm_cortex-a7_neon-vfpv4` (experimental) |
| `mipsel_24kc` | `https://openziti.github.io/ziti-openwrt/mipsel_24kc` (experimental) |

On the experimental 32-bit arches, drop `ziti-router` from the `opkg install` line -- it is not built for them. Install
`ziti-edge-tunnel luci-app-ziti` only.

GL.iNet users can also add the same per-arch URL through the web UI: **Admin Panel -> Applications -> Plug-ins ->
Manage Sources**. Pick the single URL matching your device.

### The GL.iNet QSDK neon-vfpv4 subtree

GL.iNet's QSDK firmware labels its architecture `aarch64_cortex-a53_neon-vfpv4`. opkg matches packages to devices by the
exact architecture *label*, and it refuses a plain `aarch64_cortex-a53` package even though the underlying ISA is
identical (NEON is mandatory in ARMv8-A; `_neon-vfpv4` is vestigial 32-bit floating-point naming). The maintainers solve
this **server-side**: the publish pipeline produces a separate `aarch64_cortex-a53_neon-vfpv4/` subtree by rewriting only
the `Architecture:` line in each non-`all` ipk's inner control file. The binary is byte-for-byte the same as the
`aarch64_cortex-a53` build. So QSDK users install straight from that subdirectory with no local repack.

Do **not** try to make a plain `aarch64_cortex-a53` feed work on QSDK by adding `arch aarch64_cortex-a53 5` to
`/etc/opkg.conf`. On QSDK that line *replaces* rather than *appends to* the device's default arch list and breaks all
subsequent package management. (If you already did this, revert with
`sed -i '/^arch aarch64_cortex-a53 5/d' /etc/opkg.conf`.) Use the matching feed subdirectory instead.

After install, restart rpcd so the LuCI backend registers: `/etc/init.d/rpcd restart`. Then enroll an identity via LuCI
(**Services -> OpenZiti -> Identities**) or the CLI. See `docs/install-gl-inet.md` for the full walkthrough.

## Known gotchas that affect installability

- **musl vs glibc -- why upstream prebuilts do not work.** The obvious shortcut of redistributing upstream's released
  `ziti-edge-tunnel` / `ziti` binaries fails: those are built against glibc (`/lib/ld-linux-aarch64.so.1`), and OpenWRT
  is musl. They will not load. This project compiles ZET from source against the musl SDK, and self-builds the router
  with `CGO_ENABLED=0` to get a static musl-portable binary. This is why the feed exists at all.
- **NSS hardware offload on QSDK devices.** GL.iNet QSDK firmware loads `qca-nss-ecm` (Qualcomm NSS hardware flow
  offload), which can bypass the Linux netfilter/tun path. In theory this could make forwarded traffic skip the `ziti0`
  TUN device and defeat both interception and fail-closed behavior. On the live GL-BE3600 it did **not** bypass ziti0 in
  practice (client traffic tunneled correctly), but it is a real caveat to test on your own QSDK device, and may need to
  be disabled for the tunneled path on some firmware revisions.
- **ziti-router size and arch limits.** The router is a large static Go binary (roughly 19 MB unpacked, tens of MB
  installed). It is built only for aarch64 and x86_64 and excluded on the 32-bit arches. Do not expect it on a
  16 MB-flash device. For the travel-router client gateway you do not need it anyway -- ZET is the engine there.
- **Small-flash 32-bit devices (mips/armv7).** The MT7621 and IPQ40xx GL.iNet boxes often have only 16-32 MB of flash.
  ZET plus its shared-library deps plus LuCI fit, but headroom is tight; check free flash with `df -h` before and after.
  These arches are also experimental (see below).
- **Firmware too old (GL.iNet 4.4 and below).** OpenWRT 21.02 / 22.03-based firmware ships libopenssl 1.1 and cannot
  load ZET. If your device is end-of-life on GL.iNet's roadmap and stuck below firmware 4.5, this feed will not work for
  it. Check **Admin Panel -> System -> Firmware**.
- **dropbear scp (manual sideload only).** If you sideload ipks by hand instead of using the feed, GL.iNet's SSH server
  is dropbear and lacks `sftp-server`; use `scp -O` to force the legacy protocol. Not an issue for the feed path.

## Tiers at a glance

- **Tier 1 -- verified.** `aarch64_cortex-a53_neon-vfpv4` on the **GL-BE3600 (Slate 7)** live, and `x86_64` via the CI
  QEMU install smoke. ZET installs, links, parses UCI, and (on the Slate) carries a full-tunnel client dataplane end to
  end. These are the recommended starting points.
- **Tier 2 -- should work, not individually hardware-tested.** Other `aarch64_cortex-a53` devices (vanilla mvebu SBCs,
  other GL.iNet QSDK boxes like GL-MT6000 / GL-AXT1800 / GL-MT3000 / GL-AX1800). Same ISA, same binary, same
  23.05-class ABI. High confidence, but each specific model is unproven here.
- **Tier 3 -- experimental.** `arm_cortex-a7_neon-vfpv4` (GL-B1300 / GL-AP1300 / GL-S1300) and `mipsel_24kc`
  (GL-MT1300 / GL-AR750S / GL-X750 / GL-AR300M). The feed publishes ZET + llhttp + LuCI for these (no router), but the
  builds are wired up as CI `continue-on-error` and have **not** been validated on hardware. If it works for you, or if
  it does not, open an issue.
- **Tier 4 -- needs rebuild or unsupported.** `aarch64_generic` / `-a72` / `-a76` (repack rule not yet added, no
  rebuild needed). Big-endian MIPS, other 32-bit ARM, riscv64 (full separate build needed). OpenWRT 22.x and earlier
  (libopenssl 1.1 ABI mismatch) and 24.x (libopenssl 3.2, untested).

## Sources

Repo-internal (authoritative for this project): `docs/compatibility.md`, `docs/gl-inet-sdk-research.md`,
`docs/install-gl-inet.md`, `docs/installing.md`, `docs/feed-hosting.md`, `docs/feed-publishing-setup.md`,
`docs/travel-router-buildlog.md`, `tools/build-sdk.sh`, `.github/workflows/publish-feed.yml`, the package Makefiles,
and the live feed manifest at https://openziti.github.io/ziti-openwrt/feed-info.json.

External device/arch references:

- OpenWRT targets overview (arch-to-target mapping): https://openwrt.org/docs/techref/targets/start
- GL.iNet product datasheets: https://www.gl-inet.com/products/datasheet/
- GL.iNet Slate 7 (GL-BE3600): https://www.gl-inet.com/en-us/products/gl-be3600 (this project's live recon reports the
  SoC as Qualcomm IPQ5332)
- GL.iNet Flint 2 (GL-MT6000, MT7981B): https://www.gl-inet.com/en-us/products/gl-mt6000
- GL.iNet GL-MT1300 (Beryl, MT7621): https://wikidevi.wi-cat.ru/GL.iNet_GL-MT1300_(Beryl)
- GL.iNet GL-AX1800 (Flint, IPQ6000): https://wikidevi.wi-cat.ru/GL.iNet_GL-AX1800_(Flint)
