# Architecture

## Components

```
+--------------------+        +------------------------------+
|  luci-app-ziti     | -----> |  /etc/config/ziti (UCI)      |
|  (web UI, JS)      |        |  /etc/config/ziti-router     |
+--------------------+        +------------------------------+
        |                                |               |
        | rpcd "ziti" object              v               v
        v                     +------------------+  +------------------+
+----------------------+      | /etc/init.d/     |  | /etc/init.d/     |
| /usr/libexec/rpcd/   |----->| ziti-edge-tunnel |  | ziti-router      |
| ziti (shell backend) |      +------------------+  +------------------+
+----------------------+              |                       |
                                      v                       v
                          +----------------------+  +----------------------+
                          |  ziti-edge-tunnel    |  |  ziti-router         |
                          |  (C, all arches)     |  |  (Go, aarch64/x86_64)|
                          +----------------------+  +----------------------+
                                      |                       |
                                      v                       v
                              /etc/ziti/identities    /etc/ziti/router
```

Each daemon owns its own UCI file and init script. The LuCI app drives ZET only;
the router is configured out-of-band today (enroll via `ziti router enroll`),
with a future LuCI tab planned.

## UCI schema

`/etc/config/ziti` (ZET):

```
config ziti 'main'
    option enabled '1'
    option log_level 'INFO'    # ERROR | WARN | INFO | DEBUG | TRACE | VERBOSE

config identity
    option name 'home'
    option file '/etc/ziti/identities/home.json'
    option enabled '1'
```

`/etc/config/ziti-router`:

```
config router 'main'
    option enabled '0'
    option config '/etc/ziti/router/config.yml'
```

## procd service contract

- ZET runs as a single process iterating all enabled identities via
  `--identity-dir`. Rationale (in init script): only one tun device + one
  embedded DNS resolver per host; multiple ZET processes collide.
- Router runs as a single process bound to its YAML config; refuses to start
  without it (loud failure for unenrolled installs).
- Both use `respawn` with backoff and `procd_set_param stdout/stderr 1` so
  `logread` captures output.
- Reload triggers: ZET watches `/etc/config/ziti`; router watches
  `/etc/config/ziti-router`.

## Filesystem layout on device

```
/etc/config/ziti                   UCI config for ZET (conffile)
/etc/config/ziti-router            UCI config for router (conffile)
/etc/ziti/identities/*.json        enrolled ZET identities (conffile glob)
/etc/ziti/router/                  router config + state (conffile)
/usr/bin/ziti-edge-tunnel          ZET binary
/usr/bin/ziti                      router multi-call binary
/usr/bin/ziti-router               symlink -> ziti
/etc/init.d/ziti-edge-tunnel       procd init for ZET
/etc/init.d/ziti-router            procd init for router
/usr/libexec/rpcd/ziti             rpcd backend for LuCI
/usr/share/rpcd/acl.d/             rpcd ACLs
/www/luci-static/resources/view/ziti/   LuCI views
```
