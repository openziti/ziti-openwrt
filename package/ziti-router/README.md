# ziti-router-bin

OpenWRT package that ships the upstream pre-built [OpenZiti](https://openziti.io)
edge router as a `.ipk`. See `RESEARCH.md` for why this is the prebuilt-binary
flavour rather than a from-source build.

## Architecture support

This package is **only** available on:

- `aarch64` (e.g. GL-iNet GL-BE3600, IPQ5332)
- `x86_64` (e.g. QEMU smoke tests, x86 appliances)

It is intentionally not built for `mips`, `mipsel`, `armv7`, or any other
small-flash target. The router binary is 30-60 MB and will not fit on an
8/16 MB flash device. **Do not** install it on such devices, even via
extroot, without understanding the boot-time requirements.

## Building

From the repo root:

```bash
bash tools/build-sdk.sh -p ziti-router -t aarch64_cortex-a53
bash tools/build-sdk.sh -p ziti-router -t x86_64
```

(Or the `.ps1` equivalent: `./tools/build-sdk.ps1 -Package ziti-router -Target ...`.)

The SDK download step pulls
`ziti-linux-arm64-<version>.tar.gz` or
`ziti-linux-amd64-<version>.tar.gz` from the upstream GitHub release and
extracts the `ziti` binary. No Go toolchain is required on the build host
or in the SDK.

## Pinned hashes

`PKG_HASH` is set per-arch via `ifeq ($(ARCH),...)` blocks in the
Makefile; values come from the upstream release's
`checksums.sha256.txt`. Bump them whenever `PKG_VERSION` changes.

## Service control

```sh
# enable + start
uci set ziti-router.main.enabled=1
uci commit ziti-router
/etc/init.d/ziti-router enable
/etc/init.d/ziti-router start

# logs
logread -e ziti-router
```

## Enrolling a router

This package installs the binary and an `init.d` wrapper. It does **not**
enroll your router for you. To enroll:

1. On your OpenZiti controller, create a router and download its
   one-time enrollment JWT.
2. Copy the JWT to the device (e.g. `/etc/ziti/router/router.jwt`).
3. Generate `/etc/ziti/router/config.yml` from the upstream template
   (see <https://openziti.io/docs/learn/quickstarts/network/local-no-docker>
   and the `ziti-router` reference docs at
   <https://openziti.io/docs/reference/configuration/router>).
4. Run enrollment on the device:

   ```sh
   ziti-router enroll /etc/ziti/router/config.yml \
       --jwt /etc/ziti/router/router.jwt
   ```

5. Once enrollment writes the identity into `/etc/ziti/router/`, set
   `enabled=1` in `/etc/config/ziti-router` and start the service.

`/etc/ziti/router/` survives sysupgrade because it lives on the overlay
and is declared as a conffile path in the package.

## Files installed

| Path                              | Purpose                          |
|-----------------------------------|----------------------------------|
| `/usr/bin/ziti`                   | upstream multi-call binary       |
| `/usr/bin/ziti-router`            | symlink -> `ziti`                |
| `/etc/init.d/ziti-router`         | procd service wrapper            |
| `/etc/config/ziti-router`         | UCI config (conffile)            |
| `/etc/ziti/router/`               | router state + config (conffile) |

## License

Apache-2.0, matching upstream `openziti/ziti`. The redistributed binary
is unmodified from the upstream release tarball.
