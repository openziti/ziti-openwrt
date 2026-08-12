# Integration notes

Working ZET `.ipk` produced for `aarch64_cortex-a53` on OpenWRT 23.05.5 musl.
See `docs/lessons-learned.md` for the full narrative; this file is the
checklist + the resolved/open TODOs.

## Pinned versions

| Component             | Version  | Source                                               |
|-----------------------|----------|------------------------------------------------------|
| OpenWRT release line  | 23.05.5  | stable, except where target requires SNAPSHOT (below)|
| ziti-edge-tunnel      | v1.18.1  | github.com/openziti/ziti-tunnel-sdk-c (PKG_RELEASE 4) |
| ziti (router)         | v1.6.15  | github.com/openziti/ziti, prebuilt linux-{arm64,amd64}|

## Reconciled cross-package conventions

After Stream A-E ran in parallel, two conflicts surfaced and were resolved
during the integration pass:

1. **Init script names.** ZET ships `/etc/init.d/ziti-edge-tunnel`; router ships
   `/etc/init.d/ziti-router`. The LuCI rpcd backend and ACL were originally
   speced against `/etc/init.d/ziti` -- now updated to call
   `/etc/init.d/ziti-edge-tunnel`. There is no unified wrapper init script.
2. **UCI files split.** ZET owns `/etc/config/ziti`; router owns
   `/etc/config/ziti-router`. The earlier draft `option mode 'tunnel|router|both'`
   in `architecture.md` is removed -- enable each daemon independently via its
   own UCI file. LuCI today only manages `ziti.main`; a router tab is a future
   addition.

## Open TODOs (must resolve before shipping)

1. **PKG_HASH placeholders.** *(Resolved.)* Hashes resolved from upstream and
   pinned:
   - `ziti-edge-tunnel`: `12f01f561a3d70db796ed73691edac5498e931284171571e2280102140f37fd0`
     (codeload source tarball at `refs/tags/v1.15.1`).
   - `ziti-router-bin` (per-arch via `ifeq ($(ARCH),...)`):
     - aarch64 / `ziti-linux-arm64-1.6.15.tar.gz`:
       `f004816086d98260b66f3d4b8f9a2e86af3b38eb49b4a59292adbe1582433996`
     - x86_64 / `ziti-linux-amd64-1.6.15.tar.gz`:
       `5c52d73d42ac7051686077ec73a150b2c7e9cce78aebeb41b39ee14ee94f1d1e`
   - Bump per-arch values whenever `PKG_VERSION` changes; values come from
     `https://github.com/openziti/ziti/releases/download/v<ver>/checksums.sha256.txt`.
2. **GL-BE3600 SDK targeting.** *(Resolved by Stream G -- URL needs periodic
   refresh.)* `tools/build-sdk.ps1` now has a dedicated
   `aarch64_cortex-a53_ipq53xx` target key mapped to `qualcommax/ipq53xx` and
   listed in `$SnapshotOnlyTargets`, so it auto-derives a snapshots SDK URL.
   Build with
   `./tools/build-sdk.ps1 -Target aarch64_cortex-a53_ipq53xx -Package ziti-edge-tunnel`.
   Caveat: the SNAPSHOT tarball filename embeds the current upstream gcc
   version and rolls forward whenever OpenWRT bumps the toolchain; if the
   default 404s, pass `-SdkUrl` with the live filename from
   <https://downloads.openwrt.org/snapshots/targets/qualcommax/ipq53xx/> or
   bump `$snapGcc` in `Get-SdkUrl`. The default `aarch64_cortex-a53` (mvebu)
   key is unchanged. Note: Stream G's sandbox also blocked outbound network
   access, so the exact current `gcc-<ver>` was not empirically verified --
   the seeded default (`gcc-13.3.0_musl`) reflects recent OpenWRT main and
   may already be stale.
3. **mbedtls vs openssl for ZET.** *(Resolved -- using openssl.)* OpenWRT's
   mbedtls is built without the debug API (`mbedtls_debug_set_threshold`)
   which tlsuv's mbedtls engine references unconditionally, causing link
   errors. Switched to `TLSUV_TLSLIB=openssl` + `+libopenssl` in DEPENDS.
   Matches NetFoundry's choice for the same reason.
4. **PowerShell parse check.** *(Resolved.)* All `.ps1` files under `tools/`
   (build-sdk, build-matrix, test-qemu, qemu-helpers, publish-feed,
   feed-server) AST-parse cleanly under `pwsh`. Re-run
   `pwsh -NoProfile -File tools/.cache/parse-all.ps1` after edits.
5. **arm_cortex-a7 SDK mapping.** Best-effort in the matrix script; may need
   per-device override. Document any device that requires a different SDK.
6. **Feed signing key custody.** *(Resolved -- see
   `docs/feed-publishing-setup.md`.)* The production usign secret key lives
   as a GitHub Actions repository secret named `USIGN_SECRET_KEY`. Only the
   `publish` job in `.github/workflows/publish-feed.yml` consumes it; the
   build jobs never see it. The matching `pub.key` is committed at
   `docs/pub.key` and republished to the feed root at deploy time.
7. **Feed hosting target.** *(Resolved -- see
   `docs/feed-publishing-setup.md`.)* `.github/workflows/publish-feed.yml`
   builds the matrix, runs `tools/publish-feed-ci.sh`, and pushes
   `build/feed/` to a `gh-pages` branch via
   `peaceiris/actions-gh-pages@v3`. The maintainer enables Pages once on
   that branch and the canonical feed lives at
   `https://<github-user>.github.io/<repo-name>/`.
8. **GL-BE3600 ABI mismatch:** see `docs/gl-inet-sdk-research.md` for option matrix.
9. **GL.iNet QSDK install path:** see `docs/install-gl-inet.md` for the
   end-to-end recipe (arch-label repack, dropbear `scp -O`, ziti0 verify) --
   verified working on a live GL-BE3600.

## Resolved by Stream J (public-feed publishing pipeline)

- `.github/workflows/publish-feed.yml` -- glue-only workflow (matrix build,
  router build, signed publish + gh-pages deploy). All real logic lives in
  `tools/*.sh` so a maintainer can reproduce the run locally.
- `tools/publish-feed-ci.sh` -- stages downloaded artifacts into
  `build/feed-input/`, materializes `USIGN_SECRET_KEY` to a 0600 file in the
  publish job's workspace, runs the existing `publish-feed` container, and
  shreds the secret immediately after.
- `tools/publish-feed.sh` -- extended with a `REPACK_TO_ARCH` env var
  ("src:dst[,src:dst]"). For each pair, the script materializes a sibling
  per-arch dir whose ipks have the inner control `Architecture:` line
  rewritten (binaries unchanged). Default in CI: rewrite
  `aarch64_cortex-a53` -> `aarch64_cortex-a53_neon-vfpv4` so GL.iNet QSDK
  users install with no local repack.
- `tools/collect-ipks.sh`, `tools/merge-artifacts.sh` -- small helpers the
  workflow uses to keep the SDK output trim and to flatten downloaded
  artifact dirs back into the per-target layout `publish-feed-ci.sh`
  expects.
- `docs/feed-publishing-setup.md` -- one-time maintainer checklist (push
  repo, generate keypair, push secret, commit pub.key, enable Pages,
  trigger first run, verify, document URLs).

## Resolved by Stream I (feed publishing)

- `tools/publish-feed.ps1` -- mirrors `build/<target>/*.ipk` into a feed dir,
  generates `Packages` + `Packages.gz` per target, optionally usign-signs
  `Packages.sig`, and writes a top-level `feed-info.json`.
- `tools/publish-feed.sh` + `tools/Dockerfile.feed` -- the actual `.ipk`
  parsing (ar -> control.tar.gz -> control) and `usign` invocation runs in a
  small alpine container, so the host needs only Docker + PowerShell.
- `tools/feed-server.ps1` -- dev-only `python -m http.server` over the feed
  directory for local sanity checks. Not for production.
- `docs/feed-hosting.md` -- usign keypair generation, publish workflow,
  GitHub Pages walkthrough (primary), S3 alternative, GL.iNet "Manage
  Sources" UI steps, `customfeeds.conf` CLI form, and how to install the
  public key under `/etc/opkg/keys/<key-id>` on the device.

## Resolved: on-device safeguards + DNS integration (live on a GL-BE3600)

These were built and live-verified on a GL-BE3600 running full-tunnel from a foreign (cowork) uplink. The
overarching hard rule across all of them: the wifi/internet -- and especially DNS -- must NEVER stop. Every failure
path falls open to plain direct internet; fail-closed is only ever the result of a SUCCESSFUL verification.

### Continuous resilience watchdog (`ziti-guard` service) -- was "mid-session black-hole", now resolved

- `/etc/init.d/ziti-guard` is a SEPARATE procd service running `/usr/libexec/ziti-boot-guard watchdog`. It is
  deliberately not a child of the ziti-edge-tunnel service: its own fall-open calls
  `/etc/init.d/ziti-edge-tunnel stop`, which would kill a child instance mid-teardown -- so it must outlive that stop.
- ROUTE-BASED trigger: it acts whenever a wildcard `/1` intercept is actually live on `ziti0`
  (`ip route show 0.0.0.0/1` contains `ziti0`), i.e. whenever full-tunnel is up -- regardless of whether
  `tunnel_mode=full` is set in UCI. This matters because the device's full-tunnel comes from an enrolled wildcard
  identity, not the LuCI toggle.
- Every `watchdog_interval` (default 10s) it runs `egress_ok`: (1) confirm `0.0.0.0/1` routes via `ziti0`; (2) curl
  any one of the configurable probe targets over HTTPS through the tunnel (healthy if ANY responds); (3) optional
  egress-IP assertion. After `watchdog_fails` (default 3) consecutive failures it runs `fall_open` and STAYS open --
  it does not auto-restart the tunnel, because re-arming a dead exit just black-holes again. `watchdog_grace`
  (default 20s) delays the first check after a (re)start.
- `fall_open` is the single owner of failure transitions: stop ZET FIRST (so it stops re-adding routes), flush
  `0.0.0.0/1`+`128.0.0.0/1`, restore `lan->wan`, reload firewall, re-check and re-flush, log LOUD if routes persist.
- Driver: a real incident. The exit terminator died mid-session (ZDEW drops its terminator), ZET kept the `/1` routes
  installed with no working exit, and all client traffic black-holed until a manual stop. The boot-only guard did not
  catch it because it was mid-session -- hence this continuous watchdog.
- UI-configurable (LuCI Settings -> Resilience watchdog): `watchdog_probes` (DynamicList), `watchdog_interval`,
  `watchdog_fails`, `watchdog_timeout`, `watchdog_grace`, `verify_expect_ip`. Read live each tick (except grace).

### Boot guard: preflight + `/etc/hosts` pin refresh

- `preflight` runs in the ziti-edge-tunnel init BEFORE starting ZET (full mode): refresh-hosts, then confirm a
  controller is reachable over the current uplink; if not, `fall_open` and do NOT start ZET -- so the `/1` routes
  never install when the tunnel cannot work (no black-hole over a dead controller / captive portal).
- `refresh-hosts` re-resolves EVERY controller (`ztAPI` + `ztAPIs[]`) across all enabled identities via direct DNS
  (busybox `nslookup`, bypassing `/etc/hosts`) and rewrites a marker-delimited managed block in `/etc/hosts`. Cleans
  stale pins (a changed controller IP otherwise blocks ZET from ever connecting). Also runs on enroll (rpcd).
- Failure counter `/etc/ziti/autostart-failures`; after `max_boot_failures` (3) boot-autostart is disabled. State is
  surfaced in LuCI status (`guard_state`, `boot_failures`) as a "Last boot check" row.

### OpenZiti DNS integration -- was "DNS coexistence / resolve-as-home" deferred, now resolved

- Bulletproof by design: dnsmasq ALWAYS keeps its own direct default resolver, untouched. We only ADD per-domain
  forwarding of chosen domains to ZET's resolver. If ZET/the tunnel is down, ONLY those domains fail; all other DNS
  resolves via dnsmasq's default. No single point of failure, no coupling to the watchdog/fall-open. NEVER point
  dnsmasq's only upstream at ZET.
- `ziti-boot-guard dns-sync` programs dnsmasq via UCI: adds `notinterface ziti0` (dnsmasq otherwise binds ziti0's IP
  and occupies the resolver address), rebuilds `server=/<domain>/<resolver-ip>` entries (removing any server rule
  pointing into `100.64.0.0/10` first, so a resolver-IP change cleans up), commits, reloads dnsmasq. Idempotent; runs
  on ZET start.
- GOTCHA discovered live: ZET's embedded resolver is at the **`.2`** of the DNS range -- `100.64.0.2` for the default
  `100.64.0.0/10` -- NOT `.1`. `.1` is the tun's own local IP (delivered locally to nothing). ZET adds
  `nameserver 100.64.0.2` to `/etc/resolv.conf` on start, and `100.64.0.2` routes into `ziti0` (there is a
  `100.64.0.0/10 dev ziti0` route). dnsmasq must forward to `.2`.
- ZET is started with `--dns-upstream <ip>` (e.g. a home pi-hole at a home LAN IP). Non-Ziti-service names hitting
  ZET's resolver are forwarded there; because the home resolver IP is itself inside the wildcard intercept, that query
  rides the tunnel and resolves at home. Ziti service names (e.g. `name.svc.0.ziti`) resolve to synthetic `100.64.x`.
- UCI: `ziti_dns_domains` (list of domains, e.g. an overlay suffix + a home DHCP domain), `dns_upstream` (home
  resolver), `dns_resolver_ip` (default `100.64.0.2`). LuCI: "OpenZiti DNS" settings section. Changes take effect on
  the next ziti-edge-tunnel restart (init runs `dns-sync` on start).
- Proven live from the cowork facility: a home name resolved via the home pi-hole over the tunnel to its home LAN IP;
  a Ziti service name resolved to a synthetic `100.64.x`; a public name resolved via dnsmasq's default (unaffected).

## Deferred (not blocking first build)

- Live per-identity controller / connection status in LuCI (needs ZET IPC
  socket integration). Today only service-level status is shown.
- `.pot` translation extraction for LuCI app.
- `logread` tab in LuCI.
- aarch64 on-device validation. Stream E's QEMU harness covers x86_64 only;
  GL-BE3600 needs separate target-board verification.
- Persistence test across reboots (overlay survival of identities).

## What the smoke test does and does not prove

QEMU x86_64 smoke (`tools/test-qemu.ps1`) green = packages install on a real
OpenWRT rootfs, depends resolve, init scripts enable cleanly, LuCI menu loads,
binary links and prints version. It does **not** exercise enrollment, data
plane, DNS interception, tproxy rules, or `ziti0` traffic -- those need a live
controller and JWT, which CI does not have.

## Build commands

`aarch64_cortex-a53` build is now the proven path. Two interchangeable
entry points:

```bash
# Bash (no PowerShell needed)
bash tools/build-sdk.sh -p ziti-edge-tunnel

# PowerShell wrapper (does the same thing)
./tools/build-sdk.ps1 -Package ziti-edge-tunnel
```

Artifacts land in `build/aarch64_cortex-a53/`:
`ziti-edge-tunnel_<ver>_aarch64_cortex-a53.ipk` plus the `llhttp9` runtime
dep. The directory will also contain ~200 unrelated `.ipk`s pulled in by
`make defconfig` (linux-firmware, kmods, etc.) -- ignore those for now;
trimming the defconfig is on the deferred list above.

For the actual GL-BE3600 (IPQ5332), pass the qualcommax SNAPSHOT target
once the SDK URL is known to resolve (the seeded gcc version may be
stale):

```bash
bash tools/build-sdk.sh -p ziti-edge-tunnel -t aarch64_cortex-a53_ipq53xx
```

For cross-target validation in QEMU:

```bash
bash tools/build-sdk.sh -p ziti-edge-tunnel -t x86_64
./tools/test-qemu.ps1 -IpkDir build/x86_64
```
