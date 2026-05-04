# Hosting an openwrt-openziti opkg feed

This document covers how to publish the `.ipk` files produced by `tools/build-sdk.ps1` as an
opkg feed that GL.iNet (and any OpenWRT) devices can install from via the device's package
manager UI or `opkg` on the CLI.

## What an opkg feed is

A static directory laid out like:

```
feed/
  feed-info.json
  aarch64_cortex-a53/
    Packages
    Packages.gz
    Packages.sig            # only if you signed
    ziti-edge-tunnel_<ver>_aarch64_cortex-a53.ipk
    ziti-router_<ver>_aarch64_cortex-a53.ipk
    luci-app-ziti_<ver>_all.ipk
  x86_64/
    Packages
    Packages.gz
    Packages.sig
    *.ipk
```

The device fetches `Packages.gz` to learn what is available, then fetches individual
`.ipk` files on `opkg install <name>`. The directory is fully static -- any HTTPS static
host works.

## Generate a usign keypair

OpenWRT's opkg verifies the feed index with a usign signature. Our
`tools/Dockerfile.feed` image bundles `usign` (compiled from openwrt's
upstream source -- alpine doesn't ship it as a package). Generate a
keypair once:

```bash
mkdir -p build/keys
docker run --rm \
    -v "$PWD/build/keys:/keys" \
    --entrypoint usign \
    openwrt-openziti-feed \
    -G -p /keys/pub.key -s /keys/sec.key -c "openwrt-openziti feed key"
```

(On Windows / Git-Bash, prefix with `MSYS_NO_PATHCONV=1` and use a
forward-slash absolute path like `D:/...`.)

Get the fingerprint (this is the filename it must have on the device):

```bash
docker run --rm \
    -v "$PWD/build/keys/pub.key:/keys/pub.key:ro" \
    --entrypoint usign \
    openwrt-openziti-feed \
    -F -p /keys/pub.key
```

Keep `sec.key` out of source control. `build/keys/` is already
gitignored. Publish only `pub.key` (it's plain text, safe to share).

## Publish

Build the per-target packages first:

```bash
bash tools/build-sdk.sh -p ziti-edge-tunnel -t aarch64_cortex-a53
bash tools/build-sdk.sh -p ziti-edge-tunnel -t x86_64
bash tools/build-sdk.sh -p luci-app-ziti -t aarch64_cortex-a53   # _all package
```

Stage the openziti `.ipk`s into a clean per-target tree (omits the ~200
unrelated `.ipk`s pulled in by `make defconfig`):

```bash
mkdir -p build/feed-input/aarch64_cortex-a53 build/feed-input/x86_64
cp build/aarch64_cortex-a53/{ziti-edge-tunnel,llhttp9}_*.ipk build/feed-input/aarch64_cortex-a53/
cp build/x86_64/{ziti-edge-tunnel,llhttp9}_*.ipk build/feed-input/x86_64/
cp build/luci/luci-app-ziti_*.ipk build/feed-input/aarch64_cortex-a53/
cp build/luci/luci-app-ziti_*.ipk build/feed-input/x86_64/
```

Publish (signed):

```bash
docker run --rm \
    -v "$PWD/build/feed-input:/ipks:ro" \
    -v "$PWD/build/feed:/out" \
    -v "$PWD/build/keys/sec.key:/keys/sec.key:ro" \
    -e IPK_ROOT=/ipks \
    -e OUT_DIR=/out \
    -e SIGN_KEY=/keys/sec.key \
    -e BASE_URL=https://your-org.github.io/openwrt-openziti \
    openwrt-openziti-feed
```

Output lands in `build/feed/`. Sanity-check the signature roundtrip:

```bash
docker run --rm \
    -v "$PWD/build/feed:/feed:ro" \
    -v "$PWD/build/keys/pub.key:/keys/pub.key:ro" \
    --entrypoint usign openwrt-openziti-feed \
    -V -m /feed/aarch64_cortex-a53/Packages \
       -p /keys/pub.key \
       -x /feed/aarch64_cortex-a53/Packages.sig
# Should print: OK
```

## Publishing publicly via GitHub Actions

For the canonical published feed (the one end users on the open internet should pull from), the project ships a
`publish-feed` GitHub Actions workflow that builds all four packages for both targets, signs the feed, and
deploys it to GitHub Pages on every push to `main`. See `docs/feed-publishing-setup.md` for the one-time
maintainer checklist (key generation, repo secret, Pages enablement).

The workflow also produces a sibling per-arch dir for GL.iNet QSDK firmware, so QSDK users add a single URL and
install without any local repack:

```
https://<github-user>.github.io/<repo-name>/aarch64_cortex-a53_neon-vfpv4/
```

(Substitute your repo's real values; the placeholders are documented in `docs/feed-publishing-setup.md`.)

The local-Docker flow below remains useful for testing changes to `tools/publish-feed.sh` before they ship and
for staging short-lived test feeds on a different host.

## Hosting

### GitHub Pages (recommended)

Best fit for this project: free, HTTPS by default, automatic CDN.

1. In your fork/repo settings, enable Pages on a branch (e.g. `gh-pages`) and a path
   (e.g. `/` or `/docs`).
2. Push the contents of `build\feed\` to that branch/path. A typical workflow:
   - CI runs `publish-feed.ps1` and produces `build/feed/`.
   - CI checks out the `gh-pages` branch into a worktree, copies the feed contents in,
     commits, and pushes.
3. Pages will serve everything at `https://<user>.github.io/<repo>/<target>/`.
4. Verify in a browser that `https://<user>.github.io/<repo>/x86_64/Packages.gz` is reachable.

Notes:
- GitHub Pages serves `.ipk` and `.gz` correctly with sensible MIME types.
- 1 GB / 100 GB-month soft limits are far above what this feed needs.

### S3 + CloudFront

1. `aws s3 sync build/feed/ s3://your-bucket/openziti-feed/ --acl public-read`
2. Front it with CloudFront for HTTPS.
3. Feed URL: `https://<dist>.cloudfront.net/openziti-feed/<target>/`.

### Any other static HTTPS host

Netlify, Cloudflare Pages, a plain nginx/caddy box -- anything that serves the
directory as-is over HTTPS works. No server-side logic is required.

## Adding the feed on a GL.iNet device

### UI (most users)

1. Admin Panel -> **Applications** -> **Plug-ins**.
2. Click **Manage Sources** (or the equivalent on your firmware version).
3. Add a new source pointing at the per-target URL, for example for a GL-BE3600
   (aarch64_cortex-a53):

   ```
   https://your-org.github.io/openwrt-openziti/aarch64_cortex-a53
   ```

4. Save. The Plug-ins list will refresh and show `ziti-edge-tunnel`, `ziti-router`,
   `luci-app-ziti`.

GL.iNet's UI generally accepts only one custom source per slot. Pick the URL that
matches your device's architecture. Mismatched arches will not install.

> **GL.iNet QSDK note.** Devices whose `opkg print-architecture` reports
> `aarch64_cortex-a53_neon-vfpv4` (GL-BE3600, GL-MT6000, and similar
> QSDK-based firmware) will refuse `.ipk`s tagged plain `aarch64_cortex-a53`,
> even though the underlying ISA is identical. The current `tools/build-sdk.sh`
> / SDK image produces vanilla `aarch64_cortex-a53` tags. Two ways to publish
> a feed those devices can install from:
>
> 1. **Repack on the publish host before staging into `build/feed-input/`.**
>    Rewrite the `Architecture:` line in each `.ipk`'s inner `control` file
>    to `aarch64_cortex-a53_neon-vfpv4` and re-roll the outer tar. The recipe
>    is in `docs/install-gl-inet.md` Step 1; the binary inside is unchanged.
>    Publish under a per-arch directory named `aarch64_cortex-a53_neon-vfpv4/`.
> 2. **Rebuild against a target whose SDK natively emits the
>    `_neon-vfpv4` tag** (for example a Qualcomm QSDK or upstream OpenWRT
>    snapshot for `qualcommax/ipq53xx`). This is the cleaner long-term answer
>    but depends on SDK availability; see `docs/gl-inet-sdk-research.md`.
>
> `luci-app-ziti` is `Architecture: all` and needs no repack regardless.

### CLI (`opkg`)

Append to `/etc/opkg/customfeeds.conf`:

```
src/gz openziti https://your-org.github.io/openwrt-openziti/aarch64_cortex-a53
```

Then:

```sh
opkg update
opkg install ziti-edge-tunnel luci-app-ziti
```

## Installing the public key on the device (signed feeds)

If you signed the feed, copy `pub.key` to the device so opkg can verify
`Packages.sig`:

```sh
# On the device
mkdir -p /etc/opkg/keys
# scp the file from the host into /tmp/pub.key first, then:
KEYID=$(usign -F -p /tmp/pub.key)
mv /tmp/pub.key /etc/opkg/keys/$KEYID
```

`/etc/opkg/keys/<key-id>` is the path opkg expects -- the filename must equal the
fingerprint that `usign -F` prints. Devices that ship `usign` (most modern OpenWRT)
can do this in place. Headless GL.iNet firmwares may not -- in that case, generate the
fingerprint on the host (`usign -F -p pub.key`) and copy under that name directly.

If you skipped signing, run opkg with `--force-signature` (per-invocation) or set
`option check_signature 0` in `/etc/opkg.conf`. Either weakens the install path; sign
your feeds in production.
