# luci-app-ziti

LuCI web UI for managing [OpenZiti](https://openziti.io) on OpenWRT 23.05.

This package targets the **client-side LuCI / luci2** style: JavaScript views
under `htdocs/luci-static/resources/view/ziti/` rendered by `luci-base`, no
server-side Lua templating.

## Layout

```
package/luci-app-ziti/
  Makefile
  README.md
  po/templates/ziti.pot
  htdocs/luci-static/resources/view/ziti/
    status.js          # service running, version, enrolled identities
    identities.js      # list + enroll (JWT upload or paste) + remove
    settings.js        # UCI form for ziti.main
  root/
    usr/share/luci/menu.d/luci-app-ziti.json
    usr/share/rpcd/acl.d/luci-app-ziti.json
    usr/share/rpcd/acl.d/luci-app-ziti-unauthenticated.json
    usr/share/rpcd/luci-app-ziti.conf
    usr/libexec/rpcd/ziti              # rpcd backend (shell, jsonfilter)
```

## Dependencies

- `luci-base` (>= 23.05)
- `ziti-edge-tunnel` (provided by Stream B in this repo)
- `rpcd`, `jsonfilter` (already on every OpenWRT image)
- An `/etc/init.d/ziti-edge-tunnel` procd script (shipped by `ziti-edge-tunnel`).
  The UI's `service_action` invokes
  `/etc/init.d/ziti-edge-tunnel {start|stop|restart|reload}`.

## Building

When this directory is dropped into the LuCI feed
(`feeds/luci/applications/luci-app-ziti`), the standard LuCI build works:

```
./scripts/feeds update luci
./scripts/feeds install luci-app-ziti
make package/feeds/luci/luci-app-ziti/compile V=s
```

The `Makefile` auto-detects whether `../../luci.mk` is present. If not (when
built standalone, e.g. via `tools/build-sdk.ps1`), it falls back to a manual
`BuildPackage` definition that copies `htdocs/` -> `/www/` and `root/` -> `/`
verbatim.

## Runtime

- ubus object: **`ziti`** (rpcd registers it from the basename of
  `/usr/libexec/rpcd/ziti`).
- Methods: `status`, `list_identities`, `enroll`, `remove_identity`,
  `service_action`.
- ACL file `luci-app-ziti.json` grants the LuCI session the right to call
  these methods and to read/write `uci ziti`.
- Identity files live under `/etc/ziti/identities/<name>.json` (mode 0600).

## Enrollment / JWT handling

JWTs are one-time-use enrollment tokens and must not leak. The flow is:

1. Browser collects the JWT (paste or `<input type="file">`); the value lives
   only in DOM state.
2. `enroll` rpcd call carries the JWT to the device over the existing LuCI
   HTTPS session.
3. The backend writes the JWT to a file under `/etc/ziti/.jwt-stage/`
   (mode 0700 dir, 0600 file, root-only -- **not** `/tmp`, which is tmpfs but
   world-readable).
4. `ziti-edge-tunnel enroll --jwt <stage> --identity /etc/ziti/identities/<name>.json`
   runs.
5. The stage file is overwritten with a zero byte and removed via `trap` on
   `EXIT INT TERM`, so it is wiped even on failure or signal.
6. The browser-side textarea / file input is cleared after the call resolves.
7. The JWT is **never** written to UCI, syslog, or `/tmp`.

## TODO

- Live identity status (controller URL, connection state, services count) --
  requires `ziti-edge-tunnel` IPC socket query; current `status.js` shows
  `unknown` for those columns.
- Per-identity enable/disable toggle in `identities.js`.
- i18n: populate `po/templates/ziti.pot` via `po/update.sh` once strings are
  stable.
- Surface logs from `logread -e ziti` in a tab.
