# GL-BE3600 / GL.iNet QSDK Build Research

Research notes captured while attempting to install our `ziti-edge-tunnel` and `llhttp9` packages on a GL.iNet
GL-BE3600 router. Documents the QSDK situation, the immediate blocker, the underlying ABI risk, and the option
matrix for resolving it.

## Background

The target device is a GL.iNet **GL-BE3600** router. Chipset: **Qualcomm IPQ5332** (aarch64, ARM Cortex-A53). The
device banner advertises `OpenWrt 23.05-SNAPSHOT`.

`opkg print-architecture` reports the device accepts:

```
arch all 1
arch noarch 1
arch aarch64_cortex-a53_neon-vfpv4 10
```

`/etc/opkg.conf` is minimal (just `dest`, `lists`, and `overlay` options).

`opkg update` pulls from the following GL.iNet feeds:

- `https://fw.gl-inet.com/releases/qsdk_v12.5/kmod-4.7/be3600-ipq53xx/Packages.gz`
- `https://fw.gl-inet.com/releases/qsdk_v12.5/packages-4.x/ipq53xx/be9300/glinet/Packages.gz`
- `https://fw.gl-inet.com/releases/qsdk_v12.5/packages-4.x/ipq53xx/be9300/packages/Packages.gz`

So GL.iNet is using **Qualcomm's QSDK v12.5**, kernel **4.x**, and packages built for the **IPQ53xx (BE9300
family)**. The feed naming reuses BE9300 for the BE3600 -- the two devices share the same SoC family and are
treated as one package universe.

## What we built

Our existing pipeline produces packages with arch label `aarch64_cortex-a53` (vanilla OpenWRT 23.05.5
mvebu/cortexa53 SDK). When we tried to install on the device:

```
opkg install /tmp/llhttp9_*.ipk /tmp/ziti-edge-tunnel_*.ipk
Unknown package 'llhttp9'.
Unknown package 'ziti-edge-tunnel'.
Collected errors:
 * pkg_hash_fetch_best_installation_candidate: Packages for llhttp9 found, but incompatible with the architectures configured
 * opkg_install_cmd: Cannot install package llhttp9.
 * pkg_hash_fetch_best_installation_candidate: Packages for ziti-edge-tunnel found, but incompatible with the architectures configured
```

So the **arch label is the immediate blocker**. Even if we fix the label, there is a second risk: an **ABI
mismatch** between our packages (linked against vanilla OpenWRT 23.05.5 libs) and the device's libs (built from
Qualcomm QSDK v12.5).

## Why the ISA itself is fine

- aarch64 (ARMv8-A 64-bit) **mandatorily** includes Advanced SIMD ("NEON"). Every aarch64 chip has it.
- The `_neon-vfpv4` suffix in Qualcomm's arch label is **vestigial**. VFPv4 is a 32-bit ARMv7 floating-point name.
  In aarch64 there is no such thing as a non-NEON chip. The suffix is a label-only difference, not an ABI
  difference.
- Our binary is compiled with `-mcpu=cortex-a53` against the Cortex-A53 in the IPQ5332. The instruction set
  matches.

The remaining concern is purely about **dynamic-library ABI**: the device's `libopenssl.so.3`, `libuv.so.1`,
`libsodium.so.23`, `libprotobuf-c.so.1`, etc. may have been compiled with different sub-versions / patches than
vanilla OpenWRT 23.05.5.

## What's NOT available

- **`gl-inet/sdk` on GitHub.** Pre-built SDK tarballs for many GL.iNet devices, but **does not include**
  GL-BE3600 / IPQ5332 / qsdk_v12.5. Newest IPQ they publish is IPQ807x-2102.
- **`gl-inet/openwrt` fork.** Only branch visible is `openwrt-19.07.8`. Their qsdk_v12.5 source either lives on
  a private branch or is published elsewhere.
- **`fw.gl-inet.com/releases/qsdk_v12.5/`** (browseable URL): 404. Their package URLs work, but directory
  listing is disabled.

## Option matrix

| Option | Effort | Risk | What you'd ship |
|---|---|---|---|
| **A.** Build from `gl-inet/openwrt` source fork | Hours of full OpenWRT build first time, then SDK works | Lowest -- exact match | Same `.ipk` we have but verifiably ABI-correct |
| **B.** Use upstream OpenWRT SNAPSHOT for `qualcommax/ipq53xx` | ~30 min (target already wired in `tools/build-sdk.sh` as `aarch64_cortex-a53_ipq53xx`, but unverified URL) | Medium -- 23.05 SNAPSHOT mainline is close to QSDK but not identical | New `.ipk` against vanilla mainline; may or may not match GL.iNet's lib ABIs |
| **C.** Static-link ZET fully | Substantial -- need to vendor `libuv`, `openssl`, `libsodium`, etc. into the build, the same way we did the Go router | Lowest runtime risk -- no shared libs at all | Big binary (~10 MB), runs on anything aarch64-musl |
| **D.** Accept the existing build with an `arch aarch64_cortex-a53 5` override in `/etc/opkg.conf` | 5 sec | Runtime-only ABI risk; reversible | Today's `.ipk` |
| **E.** Ask GL.iNet to publish their BE3600 SDK | Days, not in our control | Lowest if they say yes | Whatever they ship |

## Recommendation

**C (static-link)** is the engineering-correct long-term answer. It removes all ABI questions for any
aarch64-musl OpenWRT, GL.iNet or otherwise.

**D** is the right next step **today**. It is information-gathering: does it actually run? What symbol's missing
if not? The arch override is reversible (one `sed` line) and touches no system files.

## Reversibility (how to undo D)

```sh
sed -i '/^arch aarch64_cortex-a53 5/d' /etc/opkg.conf
opkg remove ziti-edge-tunnel llhttp9
```

## Update: Option D was executed end-to-end (and refined into "D-prime")

Option D as originally written -- `arch aarch64_cortex-a53 5` in `/etc/opkg.conf` -- turns out to be **broken
on QSDK**. That line replaces rather than appends to the device's default arch list (`all`, `noarch`,
`aarch64_cortex-a53_neon-vfpv4`), and breaks subsequent package management. The reversal `sed` line above does
restore the original list, so it's recoverable, but don't ship users that recipe.

The variant that **does** work, and was executed end-to-end on a live GL-BE3600 in a later session, is:

- Repack each `.ipk` on the build host with its `Architecture:` line rewritten from `aarch64_cortex-a53` to
  `aarch64_cortex-a53_neon-vfpv4`. The binary inside is unchanged.
- `scp -O` (legacy SCP -- dropbear lacks `sftp-server`) to the device.
- `opkg install` proceeds normally; deps resolve from the GL.iNet QSDK feed.
- ZET runs cleanly against the QSDK libs (libuv1, libopenssl3, zlib, libjson-c5, libsodium 1.0.18,
  libprotobuf-c 1.4.1, libpcap1, libatomic1) -- no symbol errors, ABI is fine in practice.

The exact recipe (commands, verification steps, dropbear gotcha, known cosmetic bugs) is now documented in
`docs/install-gl-inet.md`. That is the supported install path until Option B (vanilla
`qualcommax/ipq53xx` SNAPSHOT SDK) or Option C (full static link) lands.

## TODO / follow-ups

- [ ] Investigate `gl-inet/openwrt` `main` and `qsdk-12` branches -- we may have missed a branch in our initial
      survey. Confirm with `git ls-remote` against the upstream rather than relying on the GitHub web UI default
      branch view.
- [ ] Contact GL.iNet support and ask for the BE3600 SDK URL (or confirmation that QSDK v12.5 is unavailable to
      third parties). Track ticket reference here when opened.
- [ ] Prototype the static-link approach (Option C). Start by enumerating ZET's runtime shared-library
      dependencies (`readelf -d` on the current binary) and checking which can be vendored cleanly via the
      OpenWRT package's `Build/Compile` rules.
