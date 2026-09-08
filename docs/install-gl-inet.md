# Installing OpenZiti on GL.iNet devices

Step-by-step recipe for getting `ziti-edge-tunnel` (ZET) and `luci-app-ziti` running on a GL.iNet router. Verified
end-to-end on a **GL-BE3600** (IPQ5332, `aarch64_cortex-a53_neon-vfpv4`, GL.iNet firmware 4.7+ on a 23.05-SNAPSHOT
base). The repository publishes ipks for several arches so most current GL.iNet devices are covered without a
local build.

## Supported devices

**Firmware requirement:** GL.iNet firmware 4.5 or later (which is OpenWRT 23.05-based). Older firmware lines
(4.4 and below, on OpenWRT 21.02 / 22.03) are **not supported** -- libopenssl ABI is incompatible. If your device
is end-of-life on GL.iNet's update roadmap and stuck below 4.5, this feed will not work for you. Check
**Admin Panel -> System -> Firmware** for your current version.

Find your device's arch tag by SSH'ing in and running:

```sh
opkg print-architecture | awk '{print $2}'
```

Use the row in the table that matches the most-specific arch your device reports (the last line of the output is
usually the right one):

| Arch tag your device reports | Example GL.iNet devices | Feed subdirectory |
|---|---|---|
| `aarch64_cortex-a53_neon-vfpv4` | GL-BE3600, GL-MT6000, GL-AXT1800, GL-MT3000 (IPQ50xx/60xx/80xx) | `aarch64_cortex-a53_neon-vfpv4/` |
| `aarch64_cortex-a53` | Vanilla 23.05 ARM SBCs, generic mvebu | `aarch64_cortex-a53/` |
| `arm_cortex-a7_neon-vfpv4` | GL-B1300, GL-AP1300, GL-S1300 (IPQ4018/4019) | `arm_cortex-a7_neon-vfpv4/` (experimental, see below) |
| `mipsel_24kc` | GL-MT1300, GL-AR750S, GL-X750, GL-AR300M (newer rev) (MT7621) | `mipsel_24kc/` (experimental, see below) |
| `x86_64` | x86 OpenWRT, QEMU smoke target | `x86_64/` |

The 32-bit arches (`arm_cortex-a7_neon-vfpv4`, `mipsel_24kc`) are flagged experimental: the build is wired up but
not validated on a live device yet. Open an issue if it works for you (or if it doesn't). The router package
(`ziti-router`) is **not** built for these arches -- the Go binary is too large for the typical 16 MB flash budget
on those devices and the static-build flow assumes aarch64/x86_64. ZET + LuCI work fine.

If your device's reported arch isn't in the table above, the closest match probably works (the binary is the
same; the label is what `opkg` checks). Open an issue with the output of `opkg print-architecture` and we'll add
a server-side repack rule.

If you're on a vanilla OpenWRT device (arch tag `aarch64_cortex-a53`, no `_neon-vfpv4` suffix) follow
`docs/installing.md` instead. You don't need anything in this file.

## Shortcut: install from the public feed (no local repack required)

If the project maintainers have published the public feed (see `docs/feed-publishing-setup.md`), the easiest
path on QSDK is to skip the build-from-source plus repack dance entirely and pull the already-repacked
binaries straight off GitHub Pages. The maintainers run the repack server-side, so the
`aarch64_cortex-a53_neon-vfpv4/` subtree on the public feed already carries the correct arch label for your
device.

> **Placeholder URL.** The canonical hostname is not finalized until the maintainer picks a `<github-user>`
> and `<repo-name>` per `docs/feed-publishing-setup.md`. Substitute the real values once you have them. The
> URL pattern is fixed:
>
> ```
> https://<github-user>.github.io/<repo-name>/aarch64_cortex-a53_neon-vfpv4/
> ```

On the device:

```sh
mkdir -p /etc/opkg/keys
curl -fsSL https://<github-user>.github.io/<repo-name>/pub.key -o /tmp/pub.key
KEYID=$(usign -F -p /tmp/pub.key)
mv /tmp/pub.key /etc/opkg/keys/$KEYID

echo "src/gz openziti https://<github-user>.github.io/<repo-name>/aarch64_cortex-a53_neon-vfpv4" \
    >> /etc/opkg/customfeeds.conf
opkg update
opkg install ziti-edge-tunnel luci-app-ziti ziti-router
```

Then jump to **Step 4: Enroll an identity** below. Steps 1 through 3 (manual repack, scp, install from /tmp)
are not needed when installing from the public feed.

The rest of this document, beginning with "Why this doc exists" below, covers the manual build-and-repack path
for users who are building from source themselves or running before the public feed is up.

## Why this doc exists

GL.iNet's QSDK build labels its arch `aarch64_cortex-a53_neon-vfpv4`. Our build pipeline (vanilla OpenWRT 23.05
SDK, see `docs/installing.md` path C and `docs/feed-hosting.md`) produces `.ipk`s tagged `aarch64_cortex-a53`.
The two tags refer to identical aarch64 ISA -- NEON is mandatory in ARMv8-A and `_neon-vfpv4` is vestigial 32-bit
naming -- so binaries built for one work on the other. The mismatch is purely a label.

Two things follow:

1. You cannot `opkg install` our `.ipk` directly; opkg refuses on the label alone.
2. You cannot fix it by adding `arch aarch64_cortex-a53 5` to `/etc/opkg.conf`. On QSDK that line **replaces**
   rather than appends to the device's default arch list and breaks all subsequent package management. (If you
   tried this and got stuck, revert with
   `sed -i '/^arch aarch64_cortex-a53 5/d' /etc/opkg.conf`.)

The supported workaround is to **repack the `.ipk` with the matching arch label**, on the build host, before
copying to the device. The binary inside is not changed; only the label moves.

`luci-app-ziti` does not need repacking -- it is `Architecture: all` and `all` is in the device's accepted list.

## Prerequisites

- A GL.iNet device, SSH enabled (Admin Panel -> System -> Advanced Settings -> SSH), root password set.
- Build host with `tar`, `sed`, and standard Unix tools (Linux, macOS, or Git-Bash / WSL on Windows).
- ZET and llhttp9 `.ipk`s already built for `aarch64_cortex-a53` per `docs/installing.md` path C, plus the
  `luci-app-ziti_*_all.ipk`. These land in `build/aarch64_cortex-a53/` and `build/luci/`.
- A one-time-use enrollment JWT issued by your OpenZiti controller (a `.jwt` file).

## Step 1: Repack the `.ipk` with the matching arch label

A `.ipk` is a gzipped tar containing `./debian-binary`, `./control.tar.gz`, and `./data.tar.gz`. We extract,
edit `Architecture:` in the inner control file, and repack.

Do this for **`ziti-edge-tunnel`** and **`llhttp9`**. (Skip `luci-app-ziti`; it's `_all`.)

```bash
REPACK=/tmp/repack
SRC=/path/to/build/aarch64_cortex-a53/ziti-edge-tunnel_1.15.1-1_aarch64_cortex-a53.ipk
OUT=/tmp/ziti-edge-tunnel_1.15.1-1_aarch64_cortex-a53_neon-vfpv4.ipk

rm -rf "$REPACK" && mkdir -p "$REPACK/extracted" "$REPACK/control"
cp "$SRC" "$REPACK/orig.ipk"

# Outer .ipk is a gzipped tar
tar -xzf "$REPACK/orig.ipk" -C "$REPACK/extracted"

# Edit Architecture: in the control file
tar -xzf "$REPACK/extracted/control.tar.gz" -C "$REPACK/control"
sed -i 's/^Architecture: aarch64_cortex-a53$/Architecture: aarch64_cortex-a53_neon-vfpv4/' "$REPACK/control/control"

# Repack control, then the outer .ipk (preserve member order: debian-binary first)
tar -czf "$REPACK/extracted/control.tar.gz" -C "$REPACK/control" . --owner=0 --group=0
tar -czf "$OUT" -C "$REPACK/extracted" debian-binary control.tar.gz data.tar.gz --owner=0 --group=0
```

Repeat with `SRC` pointing at your `llhttp9_*.ipk`.

Sanity-check the new label:

```bash
tar -xzOf "$OUT" ./control.tar.gz | tar -xzO ./control | grep ^Architecture:
# Architecture: aarch64_cortex-a53_neon-vfpv4
```

## Step 2: Copy the `.ipk`s to the router

GL.iNet's SSH server is **dropbear**, which lacks `sftp-server`. Modern Windows / OpenSSH `scp` defaults to
SFTP and fails with `ash: /usr/libexec/sftp-server: not found`. Use `scp -O` to force the legacy SCP protocol
that dropbear understands:

```bash
ROUTER=192.168.8.1
scp -O /tmp/ziti-edge-tunnel_1.15.1-1_aarch64_cortex-a53_neon-vfpv4.ipk root@$ROUTER:/tmp/
scp -O /tmp/llhttp9_9.4.1-1_aarch64_cortex-a53_neon-vfpv4.ipk         root@$ROUTER:/tmp/
scp -O /path/to/build/luci/luci-app-ziti_*_all.ipk                    root@$ROUTER:/tmp/
```

## Step 3: Install on the router

SSH in:

```sh
ssh root@$ROUTER
```

Then on the device:

```sh
opkg update
opkg install /tmp/llhttp9_*.ipk /tmp/ziti-edge-tunnel_*.ipk /tmp/luci-app-ziti_*.ipk
```

`opkg` will pull the runtime deps (`libuv`, `libopenssl3`, `zlib`, `libjson-c5`, `libsodium`, `libprotobuf-c`,
`libpcap1`, `libatomic1`, `kmod-tun`, `ip-full`, `ca-bundle`) from the GL.iNet feed. The QSDK build of these
libs is ABI-compatible with our build of ZET in practice -- the following combination has been verified to
load and run cleanly:

| Library      | Version on device |
|--------------|-------------------|
| libuv        | 1.x               |
| libopenssl   | 3                 |
| zlib         | (stock)           |
| libjson-c    | 5                 |
| libsodium    | 1.0.18            |
| libprotobuf-c| 1.4.1             |
| libpcap      | 1                 |
| libatomic    | 1                 |

If `opkg install` reports "incompatible with the architectures configured", you missed Step 1 on one of the
files. Re-check `Architecture:` on each `.ipk`.

Restart `rpcd` so it picks up the new `/usr/libexec/rpcd/ziti` backend the LuCI app installed:

```sh
/etc/init.d/rpcd restart
```

## Step 4: Enroll an identity

### Via LuCI (easiest)

1. Browse to your router's LuCI: **Services -> OpenZiti -> Identities**.
2. Paste the contents of your `.jwt` file into the form.
3. Give it a name (letters, digits, `_`, `-`).
4. Click **Enroll**.

The LuCI app stages the JWT, runs `ziti-edge-tunnel enroll`, writes the identity JSON to
`/etc/ziti/identities/<name>.json` (mode 0600), and adds a `config identity` stanza to `/etc/config/ziti`.

Note: the current Enroll button does not validate that name and JWT are non-empty before firing -- clicking
with empty fields hangs the UI. Fill both in.

### Via the CLI

```sh
# Copy /tmp/foo.jwt to the router first.
ziti-edge-tunnel enroll --jwt /tmp/foo.jwt --identity /etc/ziti/identities/foo.json
chmod 600 /etc/ziti/identities/foo.json
```

Then append to `/etc/config/ziti`:

```
config identity
    option name 'foo'
    option file '/etc/ziti/identities/foo.json'
    option enabled '1'
```

The default `/etc/config/ziti` ships with an obsolete `option mode 'tunnel'` line -- harmless, ignore it.

## Step 5: Enable and start the service

```sh
/etc/init.d/ziti-edge-tunnel enable
/etc/init.d/ziti-edge-tunnel start
```

## Step 6: Verify

```sh
pgrep -a ziti-edge-tunnel              # PID + cmdline of the daemon
ip addr show ziti0                     # tun-style interface; should show 100.64.0.1
logread -f -e ziti                     # service log; look for "starting" and "controller version"
```

Notes:

- The interface name is **`ziti0`**, not `tun0`. (Older docs that say `tun0` are wrong for current ZET.)
- ZET runs an internal DNS resolver and intercepts the `100.64.0.0/10` range. Resolving any of your Ziti
  service hostnames should return an address inside that range.
- If you see `skipping file in config dir as it's not the proper type. type: 3. file: ...` in the log, your
  identity directory contains symlinks. ZET refuses to load identities through symlinks -- put the JSON files
  themselves directly under `/etc/ziti/identities/` (which is what the shipped init script and LuCI app do).

## Known cosmetic issues

- `ziti-edge-tunnel version` prints the version twice (e.g. `v1.15.1.v1.15.1`). Cosmetic; comes from cmake
  concatenating two version args at build time. The binary is fine.
- Log line "local 'ziti' group not found" appears at startup; ZET disables its IPC socket server in response.
  Without that socket, `ziti-edge-tunnel tunnel_status` and the LuCI Status tab's live-status RPC do not work.
  Service-level status (running / stopped) is still reported correctly. The package `postinst` now creates the
  `ziti` group (first free gid at or above 900), so this should not appear on a fresh install. If it does, add
  the group manually:

  ```sh
  # BusyBox lacks groupadd; append directly.
  echo 'ziti:x:900:' >> /etc/group
  /etc/init.d/ziti-edge-tunnel restart
  ```

## Recovering after a GL firmware upgrade

A GL.iNet firmware upgrade (or any OpenWRT `sysupgrade`) reflashes the root filesystem and discards `/overlay`,
where opkg-installed packages live. OpenZiti will look like it vanished: no `/usr/bin/ziti-edge-tunnel`, no
`/etc/init.d/ziti-edge-tunnel`, no LuCI tab, no `ziti0` interface.

Your configuration and, importantly, your **enrolled identities** survive, because they live under `/etc`, which a
keep-settings upgrade preserves. Verified surviving a GL 4.9.2 upgrade on a GL-BE3600:

| Survives | Lost |
|---|---|
| `/etc/ziti/identities/*.json` (enrollment intact, no re-enroll) | `/usr/bin/ziti-edge-tunnel` |
| `/etc/config/ziti`, `/etc/config/ziti-router` | `/etc/init.d/ziti-edge-tunnel`, `/etc/init.d/ziti-guard` |
| the openziti feed line in `/etc/opkg/customfeeds.conf` | `/usr/libexec/rpcd/ziti` and the LuCI views |
| the feed signing key under `/etc/opkg/keys/` | `/usr/libexec/ziti-boot-guard` |
| firewall `ziti` zone + `lan` -> `ziti` forwarding | the installed-package records themselves |
| dnsmasq per-domain `server=` lines and `notinterface ziti0` | |

Because the feed line and its signing key both survive, recovery is a reinstall, not a re-setup:

```sh
# 1. Back up the surviving UCI. The package record is gone, so /etc/config/ziti is no longer a tracked
#    conffile and opkg is free to replace it.
cp /etc/config/ziti /root/ziti.uci.bak

# 2. Reinstall. Pulls libsodium, libprotobuf-c and llhttp9 as needed; the rest is already in the firmware.
opkg update
opkg install ziti-edge-tunnel luci-app-ziti

# 3. rpcd only scans /usr/libexec/rpcd/ at startup, so it has not seen the freshly installed backend.
#    Without this the LuCI tabs render but every call fails with: RPC call to ziti/status failed with
#    error -32000: Object not found
/etc/init.d/rpcd restart
rm -f /tmp/luci-indexcache.*.json
rm -rf /tmp/luci-modulecache

# 4. Confirm the backend is registered, then hard-reload the LuCI page.
ubus list | grep ziti
ubus call ziti status
```

In practice opkg notices the differing conffile and parks the packaged copy at `/etc/config/ziti-opkg` rather than
overwriting yours, but take the backup anyway. If your settings did get replaced, restore with
`cp /root/ziti.uci.bak /etc/config/ziti` followed by `/etc/init.d/ziti-edge-tunnel restart`.

`postinst` enables and starts `ziti-guard` on its own, and if `/etc/config/ziti` has `enabled 1` the guard starts
ZET, so the tunnel can come back up without an explicit start. Check `ubus call ziti status` rather than assuming.

Note that the reinstall relinks against whatever libraries the new firmware ships, which is the point. Do not try
to preserve the binaries across the upgrade by listing them in `/etc/sysupgrade.conf`: ZET is dynamically linked,
and carrying it onto a rootfs with a bumped `libopenssl` or `libuv` gives you a binary that fails to load or, worse,
loads and misbehaves. Reinstalling from the feed is the supported path.

### Where the LuCI UI actually lives on GL firmware

GL's own nginx owns `:80` and `:443` and serves `/cgi-bin/` through `fcgiwrap` (see `location /cgi-bin/` in
`/etc/nginx/conf.d/gl.conf`), so LuCI is reachable on the normal port even though the nginx config never mentions
LuCI by name. uhttpd also listens directly:

```
http://192.168.8.1/cgi-bin/luci            # via GL's nginx + fcgiwrap
http://192.168.8.1:8080/cgi-bin/luci       # uhttpd directly
https://192.168.8.1:8443/cgi-bin/luci      # uhttpd, TLS
```

The OpenZiti tabs are under **Services -> OpenZiti**.

## Uninstalling

```sh
opkg remove luci-app-ziti
opkg remove ziti-edge-tunnel
opkg remove llhttp9                 # if no other package depends on it
rm -rf /etc/ziti                    # identities + config; back up first if you care
```
