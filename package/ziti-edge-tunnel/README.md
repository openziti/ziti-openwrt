# ziti-edge-tunnel (opkg package)

OpenWRT package for the OpenZiti C tunneler from
[`openziti/ziti-tunnel-sdk-c`](https://github.com/openziti/ziti-tunnel-sdk-c),
pinned to upstream **v1.15.1**.

For end-user install + enrollment instructions see
[`docs/installing.md`](../../docs/installing.md). This README covers the
package internals.

## What this package ships

- `/usr/bin/ziti-edge-tunnel` -- the tunneler binary.
- `/etc/init.d/ziti-edge-tunnel` -- procd service wrapper.
- `/etc/config/ziti` -- UCI config (conffile).
- `/etc/ziti/identities/` -- enrolled identity JSONs (conffile glob).

## Dependencies

Runtime (DEPENDS):
`+libuv +libopenssl +zlib +libjson-c +libsodium +libprotobuf-c +libpcap`
`+llhttp +libatomic +kmod-tun +ip-full +ca-bundle`.

Build-only (PKG_BUILD_DEPENDS): `llhttp` (sibling), `stc` (sibling).

`llhttp` and `stc` are not in the standard OpenWRT feeds and are provided
as sibling packages in this tree. `llhttp` is also a runtime dep because
upstream tlsuv links against the shared library.

## Build

```bash
bash tools/build-sdk.sh -p ziti-edge-tunnel
```

Produces `ziti-edge-tunnel_<ver>_<target>.ipk` and (because llhttp is
also built as a feed package) `llhttp9_<ver>_<target>.ipk`.

## Why openssl, not mbedtls

Upstream's tlsuv calls `mbedtls_debug_set_threshold` unconditionally.
OpenWRT's `libmbedtls` is built without the debug API to save flash, so
linking fails. Switched to `TLSUV_TLSLIB=openssl` (matches NetFoundry's
choice for the same reason). Footprint cost is acceptable on aarch64 /
x86_64 targets we support.

## Multi-identity model

The init script launches a **single** `ziti-edge-tunnel run` process and
points it at a runtime directory (`/var/run/ziti/identities/`) populated
from the enabled `config identity` sections via symlinks. Running one
process per identity would collide on the tun device and the embedded DNS
resolver, and would waste RAM on small routers. Per-identity
enable/disable works by including or omitting the symlink at (re)load
time.

## CMake configure flags worth knowing

The Makefile sets these in `CMAKE_OPTIONS`:

```
-DTLSUV_TLSLIB=openssl -DUSE_OPENSSL=ON -DUSE_MBEDTLS=OFF
-DBUILD_DIST_PACKAGES=OFF -DBUILD_TESTS=OFF -DEXCLUDE_PROGRAMS=OFF
-DHAVE_LIBUV=ON -DHAVE_LIBSODIUM=ON
-DZITI_TUNNEL_BUILD_TESTS=OFF
-DDISABLE_SEMVER_VERIFICATION=ON       # tarball builds have no .git
-DGIT_VERSION=v$(PKG_VERSION) -DPROJECT_SEMVER=$(PKG_VERSION)
-DDISABLE_LIBSYSTEMD_FEATURE=ON        # no systemd on OpenWRT
-Dunofficial-sodium_DIR=...            # CMake shim aliasing vcpkg name to system libsodium
```

The `unofficial-sodium` shim file is at
`files/cmake-shims/unofficial-sodium/unofficial-sodiumConfig.cmake` and
is dropped into the build dir by a `Build/Configure` override.
