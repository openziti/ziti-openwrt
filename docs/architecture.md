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
/usr/libexec/ziti-boot-guard       full-tunnel boot safeguard (called by ZET init + rpcd enroll)
/usr/share/rpcd/acl.d/             rpcd ACLs
/www/luci-static/resources/view/ziti/   LuCI views
```

## Design decisions

### Client-gateway engine: ZET (TUN) vs edge-router tproxy

For a full-tunnel gateway -- one box that pulls **all** client traffic into the overlay and egresses it
elsewhere -- OpenZiti offers two on-device engines. This repo uses `ziti-edge-tunnel` (ZET) for the client
gateway. The rationale, so it is not re-litigated:

- **ZET (TUN + lwIP).** ZET stands up a `tun` device and installs routes (for full tunnel, the split-default
  `0.0.0.0/1` + `128.0.0.0/1`) that steer matched flows into userspace, where lwIP proxies each TCP/UDP flow
  onto the overlay. A default-route (all-traffic) intercept is exactly what the TUN datapath is built for.
- **Edge-router tunneler (`mode: tproxy`).** The router's tproxy engine makes each intercepted CIDR *local*
  by doing `ip addr add <cidr> dev lo` and redirecting via the `NF-INTERCEPT` iptables chain. It has **no
  `tun` mode.** Point that at `0.0.0.0/0` (or even a `/1`) and the router treats *every* destination as local
  -- including its own controller control-channel -- and swallows its own uplink. tproxy is the right engine
  for a **defined set** of CIDR/hostname services, not for an all-traffic default route on the same box.

So: **ZET for the client gateway's full default route; edge-router tproxy for a bounded service set** (and it
is also the natural fit for the home/egress *host* side). An all-in-one edge-router LAN-gateway design does
exist and works for the bounded case -- single identity both dialing and hosting `0.0.0.0/1`+`128.0.0.0/1`,
`/32` DHCP leases for client isolation -- but it trades away a separate, centrally-managed egress chokepoint
and puts dial+bind on one key. That approach is documented externally (not carried in this repo, as it
depends on an external source); this note captures *why the travel-router path here does not use it*.

The full-tunnel runbook and its gotchas live in `docs/full-tunnel-travel-router.md` and
`docs/how-it-works-and-gotchas.md`.
