# Installing OpenZiti on OpenWRT

End-to-end how-to for getting `ziti-edge-tunnel` (and optionally
`ziti-router` and `luci-app-ziti`) running on an OpenWRT device.

> **GL.iNet QSDK users:** if your device reports `aarch64_cortex-a53_neon-vfpv4`
> from `opkg print-architecture` (GL-BE3600, GL-MT6000, and similar QSDK-based
> firmware), follow `docs/install-gl-inet.md` instead. Our `.ipk`s are tagged
> `aarch64_cortex-a53` and need a one-step repack with the matching arch label
> before they install on QSDK. Do **not** try to fix it by adding an arch line
> to `/etc/opkg.conf` -- that breaks package management on QSDK.

There are three ways in, depending on what you have:

| You have | Use |
|---|---|
| A `.ipk` someone built and sent to you | [Sideload](#a-sideload-a-prebuilt-ipk) |
| A feed URL someone published (e.g. on GitHub Pages) | [Feed install](#b-install-from-an-opkg-feed) |
| The source tree in this repo | [Build then sideload](#c-build-from-source-then-sideload) |

After install, see [Enrolling an identity](#enrolling-an-identity).

## A. Sideload a prebuilt .ipk

Fastest path if you already have the `.ipk`. Works for the bin variant of
`ziti-router-bin` and for any `ziti-edge-tunnel_*.ipk` whose architecture
matches your device.

On the host (substitute your router's IP):

```sh
scp ziti-edge-tunnel_1.15.1-1_aarch64_cortex-a53.ipk \
    llhttp9_9.4.1-1_aarch64_cortex-a53.ipk \
    root@192.168.8.1:/tmp/
```

On the router:

```sh
opkg update
opkg install /tmp/llhttp9_*.ipk /tmp/ziti-edge-tunnel_*.ipk
```

`opkg` will pull in any missing runtime deps (`libuv`, `libopenssl`,
`zlib`, `libjson-c`, `libsodium`, `libprotobuf-c`, `libpcap`, `libatomic`,
`kmod-tun`, `ip-full`, `ca-bundle`) from your device's existing feeds.

Then enable the service:

```sh
/etc/init.d/ziti-edge-tunnel enable
```

(It will not actually start until at least one identity is enrolled --
see [Enrolling an identity](#enrolling-an-identity).)

## B. Install from an opkg feed

This is what the GL.iNet "Plug-ins" page calls a custom source. Once the
feed publisher (you or someone else) has set this up via
`docs/feed-hosting.md`, an end user does:

### From the GL.iNet web UI

1. Admin Panel -> **Applications** -> **Plug-ins**.
2. Click **Manage Sources**.
3. Add the per-architecture URL, for example for the GL-BE3600
   (aarch64_cortex-a53):

   ```
   https://your-org.github.io/openwrt-openziti/aarch64_cortex-a53
   ```

4. Save and refresh. `ziti-edge-tunnel` and `luci-app-ziti` show up with
   Install buttons.

### From the CLI

```sh
echo "src/gz openziti https://your-org.github.io/openwrt-openziti/aarch64_cortex-a53" \
    >> /etc/opkg/customfeeds.conf
opkg update
opkg install ziti-edge-tunnel luci-app-ziti
```

### If the feed is signed (recommended)

The publisher will provide a `pub.key`. Install it once:

```sh
mkdir -p /etc/opkg/keys
# scp pub.key to /tmp/ first
KEYID=$(usign -F -p /tmp/pub.key)
mv /tmp/pub.key /etc/opkg/keys/$KEYID
```

Skipping signature verification is possible (`opkg --force-signature` per
invocation, or `option check_signature 0` in `/etc/opkg.conf`) but not
recommended for production.

## C. Build from source, then sideload

If you cloned this repo and want to build for your own device.

Prerequisites (on the build host):
- Docker Desktop (Windows/macOS) or Docker Engine (Linux), running.
- ~2 GB free disk for the OpenWRT SDK image + build tree.

Build the ZET package:

```bash
bash tools/build-sdk.sh -p ziti-edge-tunnel
```

(Or `./tools/build-sdk.ps1 -Package ziti-edge-tunnel` from PowerShell.)

The output `.ipk`s land in `build/<target>/`, where `<target>` defaults to
`aarch64_cortex-a53` (works for the GL-BE3600 and many other ARM SBCs).
For other targets:

```bash
bash tools/build-sdk.sh -p ziti-edge-tunnel -t x86_64
bash tools/build-sdk.sh -p ziti-edge-tunnel -t aarch64_cortex-a53_ipq53xx
```

(See `docs/integration-notes.md` for the full target list and SNAPSHOT
caveats.)

Then sideload as in path A.

## Enrolling an identity

ZET needs at least one enrolled identity (a JSON file holding the
device's keypair + controller address) before it does anything. You get
this by trading a JWT enrollment token issued by your OpenZiti controller.

### Via the LuCI app (easiest)

1. Browse to your router's LuCI: **Services -> OpenZiti -> Identities**.
2. Paste the JWT into the form, give it a name (letters/digits/`-`/`_`).
3. Click Enroll.

The LuCI app stages the JWT in `/etc/ziti/.jwt-stage/` (0700 dir, 0600
file, wiped after use), runs `ziti-edge-tunnel enroll`, writes the
identity JSON to `/etc/ziti/identities/<name>.json`, and adds a `config
identity` stanza to `/etc/config/ziti`.

### Via the CLI

```sh
ziti-edge-tunnel enroll \
    --jwt /tmp/foo.jwt \
    --identity /etc/ziti/identities/foo.json
```

Then append a stanza to `/etc/config/ziti`:

```
config identity
    option name 'foo'
    option file '/etc/ziti/identities/foo.json'
    option enabled '1'
```

And reload:

```sh
/etc/init.d/ziti-edge-tunnel reload
```

## Verifying it's working

```sh
ziti-edge-tunnel version
/etc/init.d/ziti-edge-tunnel status        # if available on your version
pgrep -a ziti-edge-tunnel                  # should print the running PID
ip addr show ziti0                          # tun device should exist once an identity is up
logread -e ziti                             # service logs
```

## Uninstalling

```sh
opkg remove ziti-edge-tunnel
opkg remove llhttp9                         # if no other package depends on it
# /etc/config/ziti and /etc/ziti/identities/ are conffiles -- remove manually if desired
rm -rf /etc/ziti
```

## Troubleshooting

- **Service won't start:** check `logread -e ziti`. Missing identities
  produce a "no identities" message; a missing `kmod-tun` produces a tun
  device error (run `opkg install kmod-tun`).
- **DNS doesn't resolve Ziti hostnames:** ZET runs an internal DNS
  resolver; you may need to forward a zone from `dnsmasq` to ZET. See the
  deferred items in `docs/integration-notes.md`.
- **Architecture mismatch on `opkg install`:** verify with
  `cat /etc/openwrt_release | grep DISTRIB_TARGET` on the device and
  compare against the `.ipk` filename suffix.
