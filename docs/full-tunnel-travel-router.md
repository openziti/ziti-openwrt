# Full-tunnel travel router over OpenZiti -- design and runbook

Goal: a GL.iNet Slate 7 (GL-BE3600) travel router sends ALL client traffic -- except the OpenZiti control/data
underlay and the local uplink -- through the OpenZiti overlay to a home-side exit node, so every device behind the
Slate appears to be sitting on the home network (home ISP public IP). Home LAN devices and services -- a NAS,
a home media server, printers, internal dashboards -- and any site that keys on source IP then behave as if you
were home.

Controller + edge router already run in AWS. The exit node is a Windows laptop in the home cabinet, "sg3", reachable
by RDP.

---

## 0. The finding that reshapes the design

OpenZiti is an application-layer (L4) overlay, NOT an IP/packet VPN. The client tunneler (ZET) intercepts TCP/UDP
flows; the hosting side (`host.v1`) opens brand-new outbound sockets from the exit host's own stack to the original
destination. Consequences:

1. **The exit node self-NATs.** Because sg3 originates the outbound sockets locally, its kernel source-NATs them like
   any local process. No `New-NetNat`, RRAS, ICS, or `IPEnableRouter` is required on Windows. This is the opposite of
   a WireGuard/OpenVPN exit and removes the single biggest piece of Windows pain.
2. **TCP and UDP only -- no ICMP.** The config schema restricts protocols to `["tcp","udp"]`. Ping/traceroute will not
   traverse the overlay. Browsing, video, QUIC/HTTP-3, DNS all work; `ping 8.8.8.8` from a client will not. Test
   with `curl`, never `ping`.
3. **Userspace throughput ceiling.** ZET proxies every flow in userspace on both ends. On an IPQ5332 travel router
   pushing all traffic, CPU is the likely bottleneck; expect well below kernel-VPN throughput. Fine for browsing and
   video on a couple of devices, which is the stated use case.
4. **Engine: ZET, NOT the ziti-router tproxy.** The travel router runs `ziti-edge-tunnel` (TUN + lwIP), not a
   ziti-router edge-router-with-tunneler. The router's tproxy mode makes each intercepted CIDR local via
   `ip addr add <cidr> dev lo`, so a `0.0.0.0/0` (or even `/1`) intercept makes the router treat every destination as
   local and swallows its own controller control-channel -- and the router has no `tun` mode. ZET's TUN datapath is
   what makes an all-traffic default-route tunnel work at all. ziti-router tproxy stays the right tool for
   intercepting a DEFINED set of CIDR/hostname services, and for the home egress side in host mode (section 3) -- just
   not for the client gateway's full default route.

---

## 1. Topology

```
[client devices] --LAN--> [Slate 7 / GL-BE3600]
                             ZET client id: travel-router-01  (#travel-clients)
                             intercept 0.0.0.0/1 + 128.0.0.0/1 -> ziti0
                                 |
                                 |  OpenZiti overlay (TLS over the remote Wi-Fi underlay)
                                 v
                          [AWS controller + edge router]   <-- underlay stays DIRECT (auto-excluded)
                                 |
                                 v
                          [sg3 / Windows laptop @ home]
                             ZET host id: home-exit-01  (#internet-exit)
                             host.v1 forward-to-original-dst -> opens local sockets
                                 |
                                 v
                          home ISP  +  home LAN  (remote sites see the home IP)
```

One Ziti service, `internet-exit-svc`, carries both configs. Authorization is by role attribute, so minting another
traveling identity later is just `create identity ... -a travel-clients` -- no policy edits.

---

## 2. Part A -- Controller (AWS): create the service, attribute-based

Run on a host with `ziti` CLI logged into your controller. `#` = role attribute (matches by tag), `@` = a specific
entity by name.

```bash
# 2.1 Configs
# Split-/1 intercept: wins over the OS default route without clobbering it. IPv4-ONLY for v1 -- IPv6 is deliberately
# omitted (see risk 6.6 and section 4.6); a half-wired IPv6 stack is a leak path, so it is a separate later runbook.
ziti edge create config internet-intercept intercept.v1 \
  '{"protocols":["tcp","udp"],"addresses":["0.0.0.0/1","128.0.0.0/1"],"portRanges":[{"low":1,"high":65535}]}'

# host.v1: forward each flow to the destination the client originally asked for. IPv4-only for v1 to match the
# intercept above; add "::/0" only when you build the IPv6 runbook.
ziti edge create config internet-host host.v1 \
  '{"forwardProtocol":true,"allowedProtocols":["tcp","udp"],"forwardAddress":true,"allowedAddresses":["0.0.0.0/0"],"forwardPort":true,"allowedPortRanges":[{"low":1,"high":65535}]}'

# 2.2 Service, tagged so policies match by attribute
ziti edge create service internet-exit-svc -c internet-intercept,internet-host -a internet-services

# 2.3 Service policies by role attribute
ziti edge create service-policy internet-bind Bind \
  --service-roles '#internet-services' --identity-roles '#internet-exit'   --semantic AnyOf
ziti edge create service-policy internet-dial Dial \
  --service-roles '#internet-services' --identity-roles '#travel-clients'  --semantic AnyOf

# 2.4 Router reachability -- SKIP if you already have blanket #all edge-router policies
ziti edge create edge-router-policy allEdgeRouters \
  --edge-router-roles '#public' --identity-roles '#all'
ziti edge create service-edge-router-policy allSvcRouters \
  --edge-router-roles '#public' --service-roles '#all'

# 2.5 Identities (pre-tagged so the policies above already authorize them)
ziti edge create identity home-exit-01     -a internet-exit   -o home-exit-01.jwt
ziti edge create identity travel-router-01 -a travel-clients  -o travel-router-01.jwt

# 2.6 Sanity check before touching either box
ziti edge policy-advisor services -q     # every line should show the id/service/router all lining up
```

Note: on some `ziti` versions `create identity` still wants a subtype token (`... create identity device NAME`).
Check `ziti edge create identity --help` on your build.

---

## 3. Part B -- Exit node sg3 (Windows): host the service, no NAT

sg3 just needs normal internet and the tunneler running in host mode. NO NAT, NO IP forwarding.

1. Install the `ziti-edge-tunnel` binary for Windows (the same background service that powers Ziti Desktop Edge;
   running the CLI binary as a Windows service is the reliable hosting path -- do not assume the ZDEW GUI exposes a
   bind/host toggle).
2. Enroll the host identity:
   ```
   ziti-edge-tunnel enroll -j home-exit-01.jwt -i C:\ProgramData\ziti\home-exit-01.json
   ```
3. Run in HOST mode (reverse-proxy only; no TUN, no DNS on the exit):
   ```
   ziti-edge-tunnel run-host -i C:\ProgramData\ziti\home-exit-01.json
   ```
   Install that as a Windows service (sc.exe / nssm / the ZET installer's service) so it survives reboot.
4. Verify Windows will egress cleanly (checks only -- change nothing unless a check fails):
   ```powershell
   Get-NetRoute -DestinationPrefix 0.0.0.0/0                              # a default route exists
   Get-NetIPInterface -AddressFamily IPv4 | Sort-Object InterfaceMetric   # right NIC wins if multihomed
   Get-NetFirewallRule -Direction Outbound -Action Block | ? Enabled -eq True   # nothing blocks the tunneler
   ```
   Only real gotcha: on a multihomed sg3, source-address selection (RFC 6724) could pick the wrong NIC. Fix with
   interface metric, not NAT.

Bonus: because `allowedAddresses` is `0.0.0.0/0`, sg3 also reaches your home LAN (e.g. 192.168.x.x), so home resources
are available through the same service.

---

## 3b. Prove the wildcard exit actually forwards -- do this BEFORE touching the Slate

`allowedAddresses: 0.0.0.0/0` is schema-valid, but it is NOT confirmed that every ZET/controller version honors a CIDR
for forward-to-original-destination at runtime. The failure mode is nasty: the service authorizes cleanly, policy-
advisor is green, and then every real flow is rejected at dial time -- so the Slate's routing and firewall would look
perfect while nothing works, and you would debug the wrong box. Prove forwarding on a throwaway dialer first (about 5
minutes, from your laptop -- no Slate involved), with sg3's `run-host` already up:
```
# one-off test dialer; same #travel-clients tag so the Dial policy already covers it
ziti edge create identity svc-smoketest -a travel-clients -o svc-smoketest.jwt
ziti-edge-tunnel enroll -j svc-smoketest.jwt -i svc-smoketest.json
ziti-edge-tunnel run -i svc-smoketest.json &     # brings up a local ziti0 on the laptop
curl -sS https://ifconfig.me                     # MUST return sg3's HOME public IP -- proves forward + egress end to end
curl -v -o /dev/null http://93.184.216.34/       # bare IP, plain HTTP -- ANY reply proves CIDR (non-DNS) forwarding; no TLS-cert false negatives
```
On sg3, watch the host tunneler log while those run: you should see it accept and dial the ORIGINAL destination for
each flow. If instead you see dial/authorization rejections for the forwarded address, this version does NOT accept the
CIDR wildcard -- replace `allowedAddresses` in the `internet-host` config with the wildcard form documented for your
version and re-run this test before going near the Slate. Tear down: stop the dialer, then
`ziti edge delete identity svc-smoketest`.

---

## 4. Part C -- Travel router (Slate 7 / GL-BE3600): ZET + the network plumbing

The packaging runs `ziti-edge-tunnel run --identity-dir /etc/ziti/identities` with defaults (interface `ziti0` at
`100.64.0.1`, DNS range `100.64.0.0/10` with the resolver at `100.64.0.2`) plus enroll + on/off + log level. The base
tunneler does ZERO firewall/route wiring -- sections 4.3-4.5 are the manual form of that -- but the package now
automates the load-bearing safeguards and the DNS integration; see section 4b.

### 4.1 Install ZET from the feed
On the GL-BE3600, opkg against the `aarch64_cortex-a53_neon-vfpv4/` subtree of the feed (the server-side repack of the
`aarch64_cortex-a53` build; the ISA is identical, `_neon-vfpv4` is a vestigial QSDK label):
```
opkg update
opkg install ziti-edge-tunnel luci-app-ziti
```

### 4.2 Enroll the client identity
```
ziti-edge-tunnel enroll --jwt /tmp/travel-router-01.jwt --identity /etc/ziti/identities/travel-router-01.json
chmod 600 /etc/ziti/identities/travel-router-01.json
/etc/init.d/ziti-edge-tunnel restart
ziti-edge-tunnel dump | head -n 40     # confirm identity + service internet-exit-svc present
ip addr show ziti0                     # confirm 100.64.0.1 is up
ip route | grep -E '0.0.0.0/1|128.0.0.0'   # confirm ZET added the intercept routes to ziti0
```

### 4.2b Prove the underlay stays direct -- REQUIRED, and do it before 4.5 fail-closed
The wide /1 intercept only works if ZET keeps its OWN sockets to the AWS controller and to every edge router on the
WAN underlay, NOT on ziti0. ZET is supposed to auto-add host-route exclusions for those endpoints when it applies the
intercept, but that behavior is version-dependent. If it misfires, ZET routes the very control/data channel it needs
into the tunnel it is trying to build -- a boot deadlock or reconnect loop that is miserable to diagnose from a hotel
room. Prove it instead of assuming it. With ZET running:
```
ip route show default             # note the current WAN gateway + device (this changes at every location)
ip route get <controller-ip>      # MUST show 'dev <wan-dev>', NOT 'dev ziti0'
ip route get <edge-router-ip>     # repeat for EVERY edge router the identity uses
```
Get the endpoint IPs from `ziti-edge-tunnel dump` or your controller config. If any resolves to `dev ziti0`, ZET's
exclusion is not working on your build and you must fix it before relying on the tunnel.

Fix if it fails: the durable fix is running a ZET build whose exclusion works, because a hardcoded `ip route add <ip>
via <gw>` breaks the instant you change locations -- the WAN gateway is different at every hotel. If you must stopgap,
re-pin the endpoints to the CURRENT gateway on every WAN bring-up with a hotplug hook (this survives roaming):
```
# /etc/hotplug.d/iface/99-ziti-underlay   (runs on each ifup)
[ "$ACTION" = ifup ] && [ "$INTERFACE" = wan ] || exit 0
GW=$(ip route show default dev "$DEVICE" | awk '/default/{print $3; exit}')
for ip in <controller-ip> <edge-router-ip>; do
    [ -n "$GW" ] && ip route replace "$ip/32" via "$GW" dev "$DEVICE"
done
```
Combined with pinning the control-plane names locally (section 4.2c), this also guarantees the 4.5 DNS-leak rule can
never starve ZET of the lookup it needs to connect. Apply 4.5 fail-closed ONLY after this check passes -- otherwise
fail-closed masks the deadlock as plain "no connectivity" and you chase the wrong problem.

### 4.2c Pin the control-plane names locally -- REQUIRED, this is what makes fail-closed safe
After 4.4 the router resolves via dnsmasq -> 1.1.1.1, and after 4.5 that query is REJECTED over WAN whenever the tunnel
is down. So on every cold boot or hotel-uplink change ZET must resolve the controller (and any DNS-named edge routers)
WITHOUT the tunnel and WITHOUT the blocked public resolver, or it deadlocks: no tunnel until it reaches the controller,
and it cannot reach the controller until the tunnel is up. Break the loop by pinning those names to IP literals in
`/etc/hosts`, which musl resolves before it ever issues a DNS query:
```
# one line per control-plane endpoint that appears as a HOSTNAME (check the identity JSON for the exact names)
cat >> /etc/hosts <<'EOF'
203.0.113.10   ctrl.example.ziti     # controller FQDN, exactly as written in the identity JSON
203.0.113.11   er1.example.ziti      # any edge router advertised by name (repeat per ER)
EOF
```
If the identity JSON already uses IP literals for the controller/ERs, ZET never resolves them and this is a no-op --
add the lines anyway, so a later controller cert/SAN change to a hostname cannot silently reintroduce the deadlock.
This is proven by the 4.7 cold-boot test; do not skip that.

### 4.3 Put ziti0 in a firewall zone and forward LAN into it
This is the "tunneler as a local gateway" topology: forwarded LAN packets that match the intercept routes get
delivered to `ziti0`, where ZET picks them up.
```
uci add firewall zone
uci set firewall.@zone[-1].name='ziti'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci add_list firewall.@zone[-1].device='ziti0'
uci set firewall.@zone[-1].masq='1'        # see note below -- safer default

uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='ziti'
uci commit firewall
/etc/init.d/firewall restart
```
`masq='1'` on the ziti zone rewrites client source IPs to `100.64.0.1` so conntrack guarantees the return path,
regardless of whether ZET routes arbitrary LAN source addresses off the tun. Client-identity preservation is
irrelevant to the exit, so masq costs nothing here. (Open question flagged for review: whether ZET handles non-local
source packets off the tun without masq -- masq sidesteps it.)

### 4.4 DNS: resolve as-if-home
NOTE: this manual approach (make the tunnel dnsmasq's ONLY upstream) is SUPERSEDED by the packaged, bulletproof DNS
integration in section 4b.3. Prefer that -- it never makes general DNS depend on the tunnel. The manual form below is
kept for understanding.

Point the router's dnsmasq at a public resolver by IP so the query itself tunnels and resolves from the home exit's
vantage point (this is what makes CDN/geo steering pick home):
```
uci set dhcp.@dnsmasq[0].noresolv='1'
uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

### 4.5 Fail-closed (recommended for a travel router -- no location leak)
By default LAN->WAN forwarding exists, so if ZET dies clients silently fall back to the local Wi-Fi and leak your real
location. Delete lan->wan forwarding so clients get internet ONLY through the tunnel. The router itself keeps WAN via
its own zone output (that is how ZET reaches the AWS underlay), so this does not break the control channel.
```
# identify the src=lan dest=wan forwarding BEFORE deleting -- read its index from this listing:
uci show firewall | grep -E "forwarding\[[0-9]+\]\.(src|dest)="
#   e.g. firewall.@forwarding[0].src='lan'  and  firewall.@forwarding[0].dest='wan'  -> index 0
uci delete firewall.@forwarding[<idx>]      # ONLY the confirmed src=lan AND dest=wan entry
uci commit firewall
/etc/init.d/firewall restart
```

Deleting lan->wan forwarding is NOT enough on its own -- it leaves a DNS leak. LAN clients use the router as their
resolver, and dnsmasq's upstream query to the public resolver is router-ORIGINATED (OUTPUT) traffic, not LAN-forwarded
traffic, so the forwarding delete does not touch it. When ZET is down its /1 routes vanish, dnsmasq's query to
1.1.1.1:53 falls back to the WAN default route, and your client lookup names + real travel-ISP source IP leak to the
upstream resolver even though web traffic is blocked. The `curl` tests would NOT catch this (they would just fail).
Close it with a WAN-output reject scoped to the resolver:
```
uci add firewall rule
uci set firewall.@rule[-1].name='block-dns-leak-wan'
uci set firewall.@rule[-1].dest='wan'          # OUTPUT leaving via the wan zone
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].dest_ip='1.1.1.1'   # one line per configured dnsmasq upstream
uci set firewall.@rule[-1].dest_port='53'
uci set firewall.@rule[-1].target='REJECT'
uci commit firewall
/etc/init.d/firewall restart
```
Because the rule is scoped to the `wan` zone it fires ONLY when the query would actually leave via WAN: tunnel up,
1.1.1.1 routes via ziti0 (not the wan zone) so the rule never matches and DNS flows through the tunnel as intended;
tunnel down, it blocks the leak. No dynamic toggling. Add one `dest_ip` per resolver if you configure more than one.

Coupling with the controller-bootstrap fix (risk 6.1): do NOT generalize this to a blanket "reject all :53 via wan"
-- the router itself may still need WAN DNS to resolve the controller at boot. Keep it scoped to the public
resolver IP(s), and pin the controller by IP (risk 6.1) so this rule can never starve ZET of the lookup it needs to
connect.

Firewall generation + PROOF (do not skip): the BE3600 runs OpenWRT 23.05 snapshot = fw4/nftables, where a
`config rule` with `dest='wan'` and no `src` renders as a router-OUTPUT rule for the wan zone (older fw3 honors the
same UCI). But do NOT trust that it matched -- if it silently does not, you are leaking DNS in exactly the state this
section exists to prevent, and no `curl` test will show it. Prove it with ZET stopped, so the /1 routes are gone and
the query would take the WAN path:
```
/etc/init.d/ziti-edge-tunnel stop
WAN=$(ip route show default | awk '/default/{print $5; exit}')   # current wan device
tcpdump -ni "$WAN" 'host 1.1.1.1 and port 53' &
nslookup example.com 127.0.0.1        # force dnsmasq to try its upstream
# EXPECT zero packets to 1.1.1.1:53 on the WAN device. Any capture = the UCI rule did not match; use the fallback.
kill %1; /etc/init.d/ziti-edge-tunnel start
```
If it leaked, drop in a device-independent nftables output rule instead. It keys off `ziti0`, not the wan name, so it
is roaming-safe at every location:
```
# /etc/nftables.d/10-dns-leak.nft   (fw4 include; apply with /etc/init.d/firewall restart)
chain ziti_dns_leak {
    type filter hook output priority 0; policy accept;
    oifname != "ziti0" ip daddr 1.1.1.1 udp dport 53 reject
    oifname != "ziti0" ip daddr 1.1.1.1 tcp dport 53 reject
}
```
This rejects the resolver query on ANY egress that is not the tunnel: blocked when ZET is down, permitted through
ziti0 when it is up. Re-run the tcpdump proof afterward.

### 4.6 Disable IPv6 for v1 -- prevents an IPv6 leak around the v4 tunnel
The intercept and host config are IPv4-only. If the Slate hands clients IPv6 or has a working IPv6 uplink, dual-stack
clients will PREFER IPv6 and bypass everything above -- a straight real-location leak that the v4 `curl` test will not
reveal. For v1, turn IPv6 off on the Slate until a proper IPv6 runbook exists:
```
# stop handing IPv6 to LAN clients
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
uci -q delete network.lan.ip6assign
# drop the IPv6 uplink client. Name varies: 'wan6' on a wired uplink, 'wwan6' when the Slate joins Wi-Fi as a repeater.
uci -q delete network.wan6
uci -q delete network.wwan6
uci commit dhcp
uci commit network
/etc/init.d/odhcpd restart
/etc/init.d/network restart
```
Verify: a LAN client shows no global IPv6 address, and `curl -6 https://ifconfig.me` from a client fails.

### 4.7 Cold-boot proof -- REQUIRED before you trust it in the field
Fail-closed only earns its keep if it survives a power cycle in a hotel with the tunnel starting from DOWN. Prove the
bootstrap does not deadlock with the DNS-leak rule live:
```
reboot
# after it comes back up, WITHOUT touching anything:
logread -e ziti-edge-tunnel | tail -n 40    # ZET reached the controller + edge routers on its own
ip route | grep -E '0.0.0.0/1|128.0.0.0'    # the /1 routes are back on ziti0
curl -s https://ifconfig.me                 # from a LAN client: returns the HOME IP -- full path came up unattended
```
If ZET hangs unable to reach the controller, the 4.2c pinning is missing or a named edge router was not pinned. Fix
`/etc/hosts` and reboot until this passes. This is the single most important test for a travel router: it is the exact
scenario you hit when you power the box on in the field.

---

## 4b. Packaged safeguards (what the init + LuCI app now automate)

Sections 4.2b-4.7 are the manual understanding. The `ziti-edge-tunnel` package (1.18.1, PKG_RELEASE 4) and
`luci-app-ziti` now automate the load-bearing parts. The hard rule behind all of it: the wifi/internet -- and
especially DNS -- must NEVER stop. Every failure path falls OPEN to plain direct internet; fail-closed is only ever
the result of a SUCCESSFUL verification. The logic lives in `/usr/libexec/ziti-boot-guard`.

### 4b.1 Boot preflight + `/etc/hosts` pin refresh
On start (full mode), the init runs `ziti-boot-guard preflight` BEFORE launching ZET:
- `refresh-hosts` re-resolves EVERY controller (`ztAPI` + `ztAPIs[]`) across all enabled identities via direct DNS
  (busybox `nslookup`, bypassing `/etc/hosts`) and rewrites a marker-delimited managed block in `/etc/hosts`. This
  cleans stale pins -- a changed controller IP otherwise blocks ZET from ever connecting. It also runs on enroll.
- It then confirms a controller is reachable on the current uplink. If not, it falls open (restores `lan->wan`,
  flushes any stray `/1` routes) and does NOT start ZET -- so the `/1` routes never install when the tunnel cannot
  work. A dead controller or captive portal can no longer black-hole the wifi.
- A failure counter (`/etc/ziti/autostart-failures`) disables boot-autostart after `max_boot_failures` (3). The last
  verdict shows in LuCI status as a "Last boot check" row (`guard_state`, `boot_failures`).

### 4b.2 Continuous resilience watchdog (`ziti-guard` service)
`/etc/init.d/ziti-guard` is a SEPARATE procd service running `ziti-boot-guard watchdog`. It is intentionally not a
child of the ziti-edge-tunnel service: its own fall-open calls `/etc/init.d/ziti-edge-tunnel stop`, which would kill
a child instance mid-teardown -- so it must outlive that stop.
- Trigger is ROUTE-BASED: it guards whenever `0.0.0.0/1` is actually routed via `ziti0` (full-tunnel live),
  independent of any `tunnel_mode` UCI flag -- because this device's full-tunnel comes from an enrolled wildcard
  identity, not the LuCI toggle.
- Every `watchdog_interval` (default 10s): confirm `0.0.0.0/1` routes via `ziti0`, then curl any one configured probe
  target over HTTPS THROUGH the tunnel (healthy if ANY responds), plus an optional egress-IP assertion. After
  `watchdog_fails` (default 3) consecutive failures it runs `fall_open` (stop ZET, flush `/1`, restore `lan->wan`,
  reload firewall) and STAYS open -- it does not re-arm a dead exit. `watchdog_grace` (default 20s) delays the first
  check after a (re)start.
- This exists because of a real incident: the exit terminator died mid-session (ZDEW drops its terminator on reboot),
  ZET kept the `/1` routes with no live exit, and clients black-holed until a manual stop. The boot-only guard could
  not catch a mid-session death.
- Tunables (LuCI Settings -> Resilience watchdog, or `ziti.main.*`): `watchdog_probes`, `watchdog_interval`,
  `watchdog_fails`, `watchdog_timeout`, `watchdog_grace`, `verify_expect_ip`.

### 4b.3 OpenZiti DNS integration (bulletproof)
Goal: resolve private Ziti service names AND home names as-at-home, WITHOUT ever risking general DNS.

Design: dnsmasq ALWAYS keeps its own direct default resolver, untouched. The package only ADDS per-domain forwarding
of chosen domains to ZET's resolver. If ZET/the tunnel is down, ONLY those domains fail; all other DNS resolves via
dnsmasq's default. There is no single point of failure and no coupling to the watchdog. Never point dnsmasq's ONLY
upstream at ZET.

`ziti-boot-guard dns-sync` (run automatically on ZET start) programs dnsmasq via UCI: it adds `notinterface ziti0`
(dnsmasq otherwise binds ziti0's IP and squats the resolver address), rebuilds `server=/<domain>/<resolver-ip>`
entries (removing any server rule pointing into `100.64.0.0/10` first, so a resolver-IP change cleans up), commits,
and reloads dnsmasq. Idempotent.

Two details that are easy to get wrong:
- ZET's embedded resolver is at the `.2` of the DNS range -- `100.64.0.2` for the default `100.64.0.0/10` -- NOT `.1`.
  `.1` is the tun's own local IP (delivered locally to nothing). ZET adds `nameserver 100.64.0.2` to
  `/etc/resolv.conf` on start, and `.2` routes into `ziti0` (there is a `100.64.0.0/10 dev ziti0` route). dnsmasq must
  forward to `.2` (`dns_resolver_ip` default).
- ZET is started with `--dns-upstream <ip>` set to your home resolver (a home LAN IP, e.g. a pi-hole). Because that IP
  is itself inside the wildcard intercept, ZET's forwarded lookup rides the tunnel and resolves at home.

Config (LuCI Settings -> OpenZiti DNS, or `ziti.main.*`):
```
uci add_list ziti.main.ziti_dns_domains='ziti'                 # overlay service suffix
uci add_list ziti.main.ziti_dns_domains='parkplace-via-dhcp'   # your home DHCP domain
uci set      ziti.main.dns_upstream='192.168.1.5'              # home resolver, reached over the tunnel
uci commit   ziti
/etc/init.d/ziti-edge-tunnel restart                           # init re-runs dns-sync on start
```
Verify from a LAN client (`<dnsmasq-ip>` is the router's LAN IP):
```
nslookup a-host.your-home-domain <dnsmasq-ip>   # -> its home LAN IP, resolved by the home resolver over the tunnel
nslookup a-service.svc.0.ziti    <dnsmasq-ip>   # -> a synthetic 100.64.x, then tunneled
nslookup example.com             <dnsmasq-ip>   # -> still resolves via dnsmasq's default, unaffected
```
Bulletproof proof: stop ZET -> the two Ziti-domain lookups fail, `example.com` still resolves.

---

## 5. Part D -- Test and verify

1. Controller: `ziti edge policy-advisor services -q` is clean; `ziti edge list service-policies` shows internet-bind
   + internet-dial.
2. sg3: `run-host` service is running; controller shows home-exit-01 online and Bound to the service.
3. Slate 7: `ziti-edge-tunnel dump` shows the service; `ip route` shows the /1 routes on ziti0.
4. From a LAN client behind the Slate:
   ```
   curl -s https://ifconfig.me        # returns the HOME ISP public IP, not the remote Wi-Fi's
   curl -s https://ipinfo.io/json     # location reads as home
   ```
   Then open a home-only service in a browser -- a NAS admin page or home media server -- it should load as if on
   the home LAN.
5. Do NOT test with `ping` -- ICMP is not carried; a failed ping is expected and means nothing.
6. **Leak checks (do both -- these are what the `curl` geo test cannot catch):**
   - DNS: with ZET stopped, the 4.5 `tcpdump` proof captures zero packets to the resolver on WAN.
   - IPv6: from a client, `curl -6 https://ifconfig.me` fails (no v6 path). If it succeeds and returns a NON-home IP,
     IPv6 is leaking -- recheck 4.6.

---

## 6. Risks / must-validate (do not skip)

1. **DNS-resolver exclusion on a wide intercept (highest risk).** ZET auto-excludes the controller, edge routers,
   default gateway, and local routes from a wide intercept -- but a known bug (openziti/ziti #2400) was that the
   system's DNS-upstream IP was NOT excluded, and if that IP fell inside the intercept, "everything stops working."
   Fixed-version unknown. Mitigation is now an executable prerequisite, not just a note: section 4.2c pins the
   controller + any named edge routers in `/etc/hosts`, and the section 4.7 cold-boot test proves ZET bootstraps with
   the tunnel down and the DNS-leak rule live.
2. **Captive portals.** Hotel/airport portals intercept HTTP to a local or public address. Traffic to the
   directly-connected uplink subnet stays direct (auto-excluded), so portals hosted on the local gateway work; portals
   that redirect to a public IP may be swallowed by the tunnel. Workaround: authenticate the portal with ZET stopped,
   then start it. Consider a LuCI/CLI toggle for this.
3. **Controller reachability behind the remote uplink.** The Slate's WAN must reach the AWS controller/routers before
   the tunnel is usable. Confirm the underlay path (and that #6.1's DNS pinning lets ZET resolve/connect at boot).
   Operationalized as a required step in 4.2b (`ip route get` each endpoint + the roaming-safe hotplug re-pin).
4. **masq-on-ziti0 assumption (4.3).** Validate return traffic with masq on; if a reason emerges to preserve client
   IPs, retest with masq off and confirm ZET routes non-local sources.
5. **Throughput.** Measure real video throughput on the BE3600; if userspace ZET is the bottleneck, see fallbacks.
6. **IPv6.** Deliberately OMITTED from the configs for v1 and disabled on the Slate (section 4.6) -- a half-wired IPv6
   stack is a straight leak path around the v4-only fail-closed. Completing IPv6 (intercept `::/1` + `8000::/1`, host
   `::/0`, a v6 firewall zone, RA/DHCPv6, and a v6 DNS-leak rule) is a separate later runbook, not a deploy-time toggle.
7. **MTU.** No published full-tunnel MTU guidance; if you see stalls on large transfers, clamp MSS on the ziti zone.

---

## 7. Fallbacks (only if the above underperforms or misbehaves)

- **Edge-router-with-tproxy on the Slate** instead of ZET: heavier, aarch64-only in this repo, no scaffolding, but a
  kernel-tproxy intercept path. Not recommended unless ZET userspace perf is unacceptable.
- **zfw (netfoundry/zfw):** eBPF firewall/diverter for OpenZiti. Linux-only, needs BTF/CO-RE (~kernel 5.15+) and
  tc-ebpf/XDP; targets full server distros. Unlikely to run on stock OpenWRT and NOT needed for the host.v1 exit
  (which self-NATs). Ignore unless you move the exit to a Linux gateway doing packet-level routing.

---

## 8. What "mint another traveler" looks like later
```
ziti edge create identity phone-02 -a travel-clients -o phone-02.jwt
```
Enroll it in any ZET (phone, laptop, another travel router). The `#travel-clients` Dial policy already authorizes it.
No controller policy edits, ever.
