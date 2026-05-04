# Public feed publishing setup (one-time)

This is the one-time checklist a maintainer follows to wire up the public opkg feed for `openwrt-openziti`. Once
this is done, every push to `main` (and every manual `workflow_dispatch`) rebuilds the four packages for both
supported targets, signs the feed, and deploys it to GitHub Pages.

End users then add a single URL in `opkg` and install `ziti-edge-tunnel`, `luci-app-ziti`, and `ziti-router`
straight from the internet -- no sideload, no repack.

The maintainer runs the steps below by hand. Nothing in the CI workflow generates keys or picks domain names.

## What you are setting up

- A signed feed at `https://<github-user>.github.io/<repo-name>/` with per-arch subdirs:
  - `aarch64_cortex-a53/` -- vanilla OpenWRT 23.05 builds (mvebu, generic ARM SBCs).
  - `aarch64_cortex-a53_neon-vfpv4/` -- same binaries, repacked control tag for GL.iNet QSDK firmware
    (GL-BE3600, GL-MT6000, etc.).
  - `x86_64/` -- vanilla OpenWRT 23.05 x86_64 (QEMU smoke testing, x86 boxes).
- The matching `pub.key` published at the feed root so end users can `curl` it directly.

## Step 1 -- Push the project repo to GitHub

If the repo is not already on GitHub, create it. Use whatever name you like; substitute it for `<repo-name>`
below. The GitHub user/org that owns it is `<github-user>`.

```bash
# from the project root, after creating an empty repo on github.com
git remote add origin git@github.com:<github-user>/<repo-name>.git
git push -u origin main
```

(Skip if the repo already exists on GitHub.)

## Step 2 -- Generate a usign keypair locally

The full procedure is in `docs/feed-hosting.md`. Short form:

```bash
mkdir -p build/keys
docker build -t openwrt-openziti-feed -f tools/Dockerfile.feed tools/

docker run --rm \
    -v "$PWD/build/keys:/keys" \
    --entrypoint usign \
    openwrt-openziti-feed \
    -G -p /keys/pub.key -s /keys/sec.key -c "openwrt-openziti feed key"
```

`build/keys/sec.key` is the secret. `build/keys/pub.key` is safe to publish. `build/keys/` is gitignored.

## Step 3 -- Add the secret key as a GitHub Actions repo secret

The secret is stored base64-encoded to dodge GitHub's multi-line textarea quirks. Get the encoded value:

```bash
base64 -w0 build/keys/sec.key
```

(PowerShell: `[Convert]::ToBase64String((Get-Content -AsByteStream build/keys/sec.key))`.)

1. In the GitHub repo, go to **Settings -> Secrets and variables -> Actions -> New repository secret**.
2. Name: `USIGN_SECRET_KEY`.
3. Value: paste the base64 string from the command above.
4. Save.

The publish job is the only job that consumes this secret. The `build-sdk` and `build-router` jobs do not
receive it, so a leaky build artifact cannot exfiltrate the key.

## Step 4 -- Commit `pub.key` to the repo

Copy the public key into `docs/pub.key` so it is checked in alongside the docs that reference it:

```bash
cp build/keys/pub.key docs/pub.key
git add docs/pub.key
git commit -m "Add usign public key for the openwrt-openziti feed"
```

The publish job also copies `docs/pub.key` to the feed root at deploy time so end users can fetch it directly:

```
https://<github-user>.github.io/<repo-name>/pub.key
```

This means there are two ways to obtain the key (repo blob URL or feed root URL); both serve the same bytes.

## Step 5 -- Enable GitHub Pages on `gh-pages`

The first publish run will create a `gh-pages` branch automatically (the workflow uses
`peaceiris/actions-gh-pages@v3` with `force_orphan: true`, which creates the branch if missing).

After the first successful run:

1. **Settings -> Pages**.
2. Source: **Deploy from a branch**, branch `gh-pages`, folder `/`.
3. Save.

Pages will then serve `https://<github-user>.github.io/<repo-name>/`.

## Step 6 -- (Optional) Custom domain

If you have a domain you want to point at the feed, configure it under **Settings -> Pages -> Custom domain**.
Add the matching DNS records (`CNAME` to `<github-user>.github.io.`) at your registrar. Pages provisions a
Let's Encrypt cert automatically.

If you take this path, also update `BASE_URL` in `.github/workflows/publish-feed.yml` (or override it with a
repo variable) so `feed-info.json` records the user-facing URL.

## Step 7 -- Trigger the first run, verify the deploy

```bash
git push origin main
# or, in the GitHub UI: Actions -> publish-feed -> Run workflow
```

Watch the run. The three jobs (`build-sdk` matrix, `build-router` matrix, `publish`) should all go green. The
`publish` job ends with a deploy step that reports the commit SHA on `gh-pages`.

Verify by hand:

```bash
curl -fsSL https://<github-user>.github.io/<repo-name>/feed-info.json
curl -fsSLI https://<github-user>.github.io/<repo-name>/aarch64_cortex-a53/Packages.gz
curl -fsSLI https://<github-user>.github.io/<repo-name>/aarch64_cortex-a53_neon-vfpv4/Packages.gz
curl -fsSLI https://<github-user>.github.io/<repo-name>/x86_64/Packages.gz
curl -fsSL  https://<github-user>.github.io/<repo-name>/pub.key
```

All five should return 200 and (for the `Packages.gz` ones) a non-trivial `Content-Length`.

## Step 8 -- Document the public URLs

End users need to know which subdirectory matches their device. Confirm and update the placeholders in
`docs/feed-hosting.md`, `docs/installing.md`, and `docs/install-gl-inet.md` once your `<github-user>` and
`<repo-name>` are settled. The public URLs look like:

| Device class | URL |
|---|---|
| Vanilla OpenWRT 23.05, aarch64 (mvebu, generic) | `https://<github-user>.github.io/<repo-name>/aarch64_cortex-a53/` |
| GL.iNet QSDK (GL-BE3600, GL-MT6000, ...) | `https://<github-user>.github.io/<repo-name>/aarch64_cortex-a53_neon-vfpv4/` |
| Vanilla OpenWRT 23.05, x86_64 / QEMU | `https://<github-user>.github.io/<repo-name>/x86_64/` |
| Public key (any device) | `https://<github-user>.github.io/<repo-name>/pub.key` |

End-user CLI form:

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

## Decisions baked into this pipeline

A handful of small design choices, recorded so future maintainers do not have to re-derive them:

- **Cache strategy.** The workflow caches the `tools/Dockerfile`-built SDK image layers and the Go module
  cache. Both are large (hundreds of MB) and rarely change. The SDK rebuild itself is not cached -- a fresh
  build per run keeps signed outputs honest. If build minutes become a concern later, a build cache per target
  is the next lever.
- **`gh-pages` branch creation.** The first workflow run creates the branch via
  `peaceiris/actions-gh-pages@v3` with `force_orphan: true`. No manual `git checkout --orphan gh-pages`
  needed.
- **`pub.key` lives in two places.** It is committed at `docs/pub.key` (so it shows up in the repo browse UI
  and is reviewable in PRs) **and** copied to the feed root at publish time (so end users can `curl` it from
  the same hostname they pull packages from, no second domain to trust). Both files are byte-identical.
- **Secret key isolation.** Only the `publish` job sees `USIGN_SECRET_KEY`. The `build-sdk` and
  `build-router` jobs never reference the secret in their `env:` blocks, so artifact uploads from those jobs
  cannot smuggle it. The `publish` job materializes the secret to a 0600 file under `build/keys/`, runs the
  signing container with that file mounted read-only, then `shred`s the file before the deploy step runs --
  belt and suspenders.
- **Repack-for-QSDK is server-side.** The pipeline produces a separate `aarch64_cortex-a53_neon-vfpv4/`
  subtree by rewriting the `Architecture:` line in each non-`all` ipk's inner control file (the recipe from
  `docs/install-gl-inet.md` step 1, mechanized in `tools/publish-feed.sh`). End users on QSDK firmware add
  the per-arch URL directly; no on-host repack is needed.

## Tasks for the human

The GitHub agent cannot do these for you. After reading this doc:

- [ ] **Maintainer first-time public-feed setup**: walk through Steps 1 through 6 above. Generate the
  keypair, push the secret to the repo, commit `pub.key`, enable Pages.
- [ ] **Verify first deploy**: run Step 7's curl checks against the live URLs and confirm a fresh OpenWRT
  device can `opkg update; opkg install ziti-edge-tunnel`. Update placeholder URLs in
  `docs/feed-hosting.md`, `docs/installing.md`, and `docs/install-gl-inet.md` once the canonical URL is
  decided.
