# How it works, and every gotcha we hit

The explanatory companion to `docs/travel-router-buildlog.md` (terse notes) and `docs/full-tunnel-travel-router.md`
(the runbook). This is the narrative: how the full-tunnel travel router actually works, why it is built the way it
is, and every dead end and trap along the way.

## 1. How it works

Goal: a device with NO OpenZiti software on it -- a phone, a laptop, a TV -- joins a wifi the travel router serves and
behaves as if it were on the home network, egressing from a chosen endpoint (home ISP or a cloud box), from anywhere.

Datapath, outbound:

1. A client on the travel router's LAN (`br-lan`, 192.168.8.0/24) sends a packet to some internet address. Its
   default gateway is the travel router.
2. The travel router runs ZET (`ziti-edge-tunnel`), the C tunneler, which creates a TUN device `ziti0` and a userspace
   TCP/IP stack (lwIP). When ZET dials the wildcard service it installs routes for the intercepted CIDRs
   (`0.0.0.0/1` + `128.0.0.0/1`) pointing at `ziti0`, in the MAIN routing table.
3. Because those routes are in the main table, the router's normal FORWARD path sends the client's internet-bound
   packet to `ziti0`. (This is also the source of the black-hole gotcha -- see below.)
4. ZET terminates the flow in lwIP, matches it to a service by destination address, and dials that service over the
   OpenZiti overlay (a mutually-authenticated TLS mesh through one or more edge routers).
5. The hosting side -- an identity authorized to Bind the service with a `host.v1` "forward to original destination"
   config -- receives the flow and opens a BRAND-NEW outbound socket from its own stack to the address the client
   originally wanted.
6. Return traffic follows the reverse path. The client never knew any of this happened.

Consequences of OpenZiti being an application-layer (L4) overlay, not an IP/packet VPN:

- TCP and UDP only. ICMP is not carried -- `ping`/`traceroute` do not traverse the overlay. Browsing, streaming,
  QUIC/HTTP-3, DNS all work.
- The exit self-NATs. Because it opens its own sockets, the exit host's kernel source-NATs them like any local
  process -- so the exit needs NO `New-NetNat`/`ip_forward`/masquerade. This is the opposite of WireGuard/OpenVPN and
  removes the biggest piece of exit-side setup.
- Egress geography is the exit's. If the exit sits on your home LAN, clients appear at your home ISP IP (Netflix sees
  home). If it is a cloud VPS, they appear there.
- Authorization is by role attribute. A Bind policy (`#internet-exit`) says who may host; a Dial policy
  (`#travel-clients`) says who may use. Add a new traveling device by creating an identity with `-a travel-clients` --
  no policy edits, ever.

## 2. The engine decision: ZET (TUN), not ziti-router tproxy

You might expect the "edge-router-with-tunneler in tproxy mode" to be the LAN-gateway tool -- it is the canonical way
to intercept OTHER hosts' traffic. It does not work for a full 0.0.0.0/0 tunnel, at the source level:

- ziti-router tproxy makes each intercepted CIDR locally routable by running `ip addr add <cidr> dev lo` (via netlink
  in `tunnel/intercept/tproxy/tproxy_linux.go` / `iputils.go`). A `0.0.0.0/0` (or even a split `/1`) intercept
  therefore makes the router treat EVERY destination as local -- it swallows its own controller control-channel and
  normal forwarding.
- The router has no `tun` mode (only `tproxy`, `host`, `proxy`; see `tunnel/router/router_linux.go`).
- It emits classic `iptables` rules, which collide with OpenWrt 23.05's fw4/nftables stack.
- There is no attested OpenWrt validation of ziti-router tproxy.

ZET works for the full-tunnel case precisely because it uses a TUN device + lwIP -- a datapath that carries a default
route without making destinations local on the box. ziti-router tproxy remains right for intercepting a DEFINED set
of CIDR/hostname services, and for the exit side in `host` mode.

## 3. Gotchas (symptom -> cause -> fix)

### The wildcard-intercept black-hole
- Symptom: start ZET with the wildcard intercept and every client on the wifi loses internet -- while you are on the
  wifi.
- Cause: the `0.0.0.0/1` + `128.0.0.0/1` routes go in the MAIN table, so route selection diverts ALL internet-bound
  traffic (the router's own AND forwarded client traffic) to `ziti0`. With no `lan->ziti` firewall forwarding accept,
  the FORWARD chain drops it. "No forwarding rule means clients are safe" is FALSE -- the global route diverts before
  the firewall, then the firewall drops.
- Fix: stage the `ziti` firewall zone + `lan->ziti` forwarding (masq on) BEFORE starting ZET, so client traffic is
  carried into the tunnel instead of dropped. Recovery if you hit it: LAN-side SSH survives (SSH to the router's own
  LAN IP is input, not forwarded), so `ziti-edge-tunnel stop` clears the routes; or reboot (keep boot-autostart off).

### The roaming / uplink-change deadlock
- Symptom: change the travel router's uplink to a new network with ZET running, and it never gets internet on the new
  network (and may wedge). Reboot fixes it.
- Cause: ZET keeps a host-route exclusion to the controller via the OLD gateway. When the uplink changes, that route
  is stale; ZET must re-reach the controller over the new network, but the live wildcard intercept catches its own
  reconnect before the tunnel exists -> deadlock.
- Fix ordering: pin the controller + edge routers in `/etc/hosts` (so ZET resolves them without the tunnel) and do a
  FRESH start on the new uplink (fresh starts re-derive the exclusion on the current gateway; we verified
  `ip route get <controller>` -> `dev <uplink>` after a clean start). Or the simple path: stop ZET, switch uplink,
  verify controller reachability, start ZET.

### DNS leak in "fail-closed"
- Symptom: after deleting `lan->wan` forwarding, web traffic is blocked when the tunnel is down but DNS still leaks.
- Cause: LAN clients resolve via the router's dnsmasq; dnsmasq's upstream query is router-ORIGINATED (OUTPUT), not
  forwarded, so the forwarding delete does not touch it. When the tunnel is down its routes vanish and the query goes
  out WAN, leaking lookup names + the real ISP IP.
- Fix: a WAN-scoped output REJECT for the resolver IP (fires only when the query would leave via WAN; self-disables
  when the tunnel is up because the resolver then routes via `ziti0`). Related: openziti/ziti #2400 -- a wide
  intercept must not swallow the system's DNS-upstream IP; pin the controller by IP so ZET never needs public DNS.

### Geo-correct DNS
- For Netflix to serve the home catalog, DNS must resolve from the exit's vantage point, not the local uplink. Point
  the router's dnsmasq upstream at a public resolver so the query itself tunnels and resolves as-if-home. (Egress IP
  being home is necessary but not sufficient; DNS steering matters too.)

### Captive portals
- Hotel/airport portals intercept HTTP to a local or public address. Directly-connected uplink traffic stays direct
  (auto-excluded), so portals on the local gateway work; portals that redirect to a public IP may be swallowed by the
  tunnel. Authenticate with ZET stopped, then start it.

### NSS hardware offload (GL.iNet QSDK)
- GL firmware loads `qca-nss-ecm` (Qualcomm hardware flow offload), which can bypass the Linux netfilter/tun path and
  make traffic skip `ziti0`. In our runs it did NOT bypass, but it is a real risk to test; disable NSS offload for the
  tunneled path if traffic mysteriously ignores the tunnel.

### masq on ziti0
- `masq=1` on the ziti zone rewrites client source IPs to `100.64.0.1`, so conntrack guarantees the return path
  regardless of whether ZET routes arbitrary LAN source addresses off the tun. Client-identity preservation is
  irrelevant to the exit, so masq costs nothing and sidesteps that uncertainty.

### IPv6
- The intercept is IPv4-only. On a dual-stack LAN, clients prefer IPv6 and bypass the v4-only fail-closed -- a real
  leak. Disable IPv6 on the LAN (and uplink) for v1. GL defaults already disable RA/DHCPv6 and dnsmasq filters AAAA,
  which helps. Full IPv6 is a separate later runbook.

### GL.iNet QSDK arch label
- GL's QSDK labels its arch `aarch64_cortex-a53_neon-vfpv4`; our build produces `aarch64_cortex-a53`. Same ISA,
  vestigial `_neon-vfpv4` suffix. Repack the ipk's inner `Architecture:` line (publish-feed.sh does this server-side;
  the public feed's `.../aarch64_cortex-a53_neon-vfpv4/` subtree is ready to `opkg install`). Do NOT add an arch line
  to `/etc/opkg.conf` on QSDK -- it REPLACES the list and breaks opkg.

### opkg signature enforcement
- The feed IS usign-signed and the key is imported, but GL ships `/etc/opkg.conf` WITHOUT `option check_signature`,
  so opkg does not enforce it. Enabling it globally BREAKS `opkg update` -- GL's own `glinet_gli_pub` feed has no
  `Packages.sig` (check_signature is global, not per-feed). So the LuCI self-update verifies the openziti feed
  EXPLICITLY: `usign -V -p <imported key> -m Packages -x Packages.sig`, and refuses to upgrade if it does not verify.
  opkg then validates the installed ipk's sha256 against the verified index. Provenance proven without breaking GL.

### GitHub codeload PKG_HASH stability
- The ZET Makefile pins `PKG_HASH` = sha256 of the codeload tarball at `refs/tags/vX`. Codeload archives are stable
  per tag once generated (verified: two fresh downloads of v1.18.1 hashed identically). A wrong PKG_HASH fails the SDK
  build on hash check -- always recompute from an actual download when bumping.

### Windows Docker vs WSL builds
- Local Docker Desktop on Windows could NOT bind-mount the repo for the SDK build: `D:\...` and `D:/...` `-v` specs
  are rejected ("invalid volume specification"), and `//d/...`, `/mnt/d/...`, `/run/desktop/...` "succeed" but mount
  an EMPTY dir. Root cause is drive-sharing/WSL2 integration, not the scripts. The working local method: build in WSL
  (`ssh cdwsl`, same Docker daemon), rsync the repo to a native path `/mnt/wsl/...` (use
  `rsync -rlD --no-times --omit-dir-times --no-perms` -- `/mnt/wsl` rejects utime/chmod, so `-a` fails with code 23),
  then `bash tools/build-sdk.sh` there with native Linux paths. Or just use CI (Linux), which is the designed path.

### LuCI view-JS browser caching
- LuCI serves view JS at version-stamped URLs that do NOT change when you scp a new view, so a plain F5 keeps the old
  JS -- and it is per-file, so hard-reloading one tab does not refresh another's. This caused hours of "the UI is
  chopped/empty" confusion while the device had the correct files. Reliable dev workaround: DevTools -> Network ->
  Disable cache, then reload. Every view now shows a `UI_BUILD` stamp; the dev deploy auto-injects a monotonic UTC
  timestamp so a stale tab is obvious.

### rpcd backend must be executable
- `/usr/libexec/rpcd/ziti` shipped 0644; rpcd only loads executable backends, so the `ziti` ubus object never
  registered -> LuCI "RPCError -32000: Object not found" + empty tabs. Fix: install it 0755 (Makefile now chmods it).

### rpcd should list the identity dir, not UCI
- The LuCI identity list originally read UCI `config identity` sections, which CLI enrollment never creates, so
  CLI-enrolled identities were invisible. Fixed to enumerate `/etc/ziti/identities/*.json` (ZET's source of truth),
  filtering out ZET's runtime `config.json` status file, and deriving controller (from the identity's `ztAPI`) +
  status (active/disabled/stopped).

## 4. Tried and abandoned

- ziti-router tproxy for full-tunnel: abandoned for the `ip addr add <cidr> dev lo` reason above.
- M1 mini as the exit: its ziti service restarted unreliably; dropped.
- Ziti Desktop Edge for Windows (sg3) as the exit: the GUI hosts a service only after a manual disable/enable, and
  drops the terminator on reboot (silently falling back to the ER). So ZDEW-hosting works but is not set-and-forget;
  the reliable Windows exit is the `ziti-edge-tunnel.exe` CLI in `run-host` wrapped as an nssm service.
- Global opkg `check_signature`: broke `opkg update` on GL's unsigned feed; replaced with explicit per-feed usign
  verification in the update action.
- Local Windows Docker builds: bind-mount failure; moved to WSL / CI.

## 5. Proving it

- Fabric events: `ziti fabric stream events` shows `circuit created` (tags: dialer/exit/service) and `connect`
  (exit's egress source address) -- the overlay proving itself live.
- The traceroute collapse: from the home LAN, `tracert eth0.me` walks the full ISP path; from behind the travel
  router the same trace collapses to two hops (gateway -> destination) because the underlay is opaque and ICMP is not
  carried.
- `curl ifconfig.me` / `curl eth0.me` from a non-Ziti client returns the exit's public IP (home or cloud), run from a
  demonstrably foreign network.
