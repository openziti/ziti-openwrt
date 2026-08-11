# Travel-router build log and decision record

Durable record of the full-tunnel travel-router effort so a future session can reconstruct state after context loss.
This is the narrative and rationale; the executable runbook is `docs/full-tunnel-travel-router.md`.

## Goal

A GL.iNet GL-BE3600 (Slate 7) travel router whose wifi lets **non-Ziti client devices** reach a chosen OpenZiti
endpoint and egress from there, with **no OpenZiti software on the clients**. Primary use: reach the home network
and its services from anywhere by egressing at a home or cloud endpoint over the OpenZiti overlay.

- Phase 1 (current): egress through a cloud **VPS**. Prove a non-Ziti client on the GL wifi shows the VPS public IP
  via `curl ifconfig.me`.
- Phase 2 (final, deferred): reach an isolated home **guest** subnet by moving the GL uplink onto that network. Last
  because it requires wifi disruption.
- Future idea: run the controller/router plus the exit on a second GL box at home -- a two-box home/away pair.

## Engine decision: ZET, not the ziti-router tproxy (the crux)

The travel router runs **ZET (`ziti-edge-tunnel`, TUN + lwIP datapath)** as the gateway, **not** a ziti-router
edge-router-with-tunneler in tproxy mode.

Why the router tproxy path fails for a full default-route tunnel, at source level:

- ziti-router tproxy makes each intercepted CIDR locally routable by running `ip addr add <cidr> dev lo`. A `0.0.0.0/0`
  (or even a split `/1`) intercept therefore makes the router treat **every destination as local**, which swallows its
  own controller control-channel and normal forwarding.
- The router has **no tun mode** -- only `tproxy`, `host`, `proxy`.
- The router emits **iptables** rules, which collide with OpenWrt 23.05's fw4/nftables stack.
- There is **no attested OpenWrt validation** of ziti-router tproxy.

Source files backing this: `tunnel/intercept/tproxy/tproxy_linux.go`, `tunnel/intercept/iputils.go`,
`tunnel/router/router_linux.go` in `openziti/ziti`.

ZET works for the full-tunnel case precisely because it uses a **TUN device + lwIP**, a different datapath that can
carry a default route without making destinations local on the box.

ziti-router tproxy remains the right tool for intercepting a **defined set** of CIDR/hostname services, and for the
egress/host side in `host` mode -- just not for the client gateway's full default route.

## Key OpenZiti facts (validated this session)

- OpenZiti is an **L4 overlay**: **TCP/UDP only**. ICMP never tunnels, so `ping` is not a valid test; use `curl`.
- `host.v1` **forward-to-original-destination self-NATs** on the exit host: the hosting tunneler opens its own
  outbound sockets, so the exit needs **no** `New-NetNat` / `ip_forward` / masquerade. This is the opposite of a
  WireGuard/OpenVPN exit and is why a Linux VPS exit is trivial.
- **Wildcard full-tunnel** uses the split-default pair `0.0.0.0/1` + `128.0.0.0/1` (covers all IPv4 without clobbering
  the OS default route). Add `::/1` + `8000::/1` only when IPv6 is done end to end.
- On a wide intercept, ZET auto-excludes the **controller, edge routers, default gateway, and local routes** from the
  tunnel. BUT the **DNS-upstream IP exclusion was a bug** (openziti/ziti #2400); fixed-version unknown -- must be
  validated on the running build.
- **Attribute/role-based** Bind + Dial service policies mean new identities are authorized simply by tagging them, no
  policy edits per identity.

## Exit options

- ZET `run-host` and ziti-router `host` mode are **equivalent** for the egress side.
- A **Linux VPS** exit is far simpler than a Windows exit (no NAT nuance, self-NAT via `host.v1` sockets).
- `zfw` (github.com/netfoundry/zfw): eBPF firewall/diverter, **Linux-only**, needs BTF/CO-RE (~kernel 5.15+). **Not
  needed** for the `host.v1` self-NAT exit and unlikely to run on stock OpenWrt. Fallback only.

## Device recon (GL-BE3600, live)

- SoC IPQ5332, **OpenWrt 23.05-SNAPSHOT**, kernel **5.4.213** (GL QSDK vendor kernel), opkg arch
  **`aarch64_cortex-a53_neon-vfpv4`**.
- LAN = `br-lan` (eth1) **192.168.8.1/24** -- the wifi clients.
- WAN `eth0` is **DOWN**. Uplink is a **wifi repeater on `sta1`**, default via **192.168.1.1** (src 192.168.1.63) -- it
  is joined to the `192.168.1.0/24` home network and the overlay underlay rides that link.
- IPv6 to LAN is already off (`dhcpv6`/`ra` disabled, dnsmasq `filter_aaaa=1`).
- `/dev/net/tun` and `kmod-tun` are present, so ZET can create its TUN.
- **GOTCHA:** the GL firewall loads **`qca-nss-ecm`** (Qualcomm NSS hardware flow offload), which can bypass the Linux
  netfilter/tun path. This may make traffic **skip `ziti0`** and defeat both interception and fail-closed. Must be
  tested and likely disabled for the tunneled path.
- Public signed feed is live at **https://openziti.github.io/ziti-openwrt** (neon-vfpv4 subtree, usign-signed).
- **Installed** this session from that feed: `ziti-edge-tunnel 1.15.1-2`, `llhttp9`, `luci-app-ziti`.
- **Cleaned** prior-experiment leftovers: a `glinettest` identity, a misfiled ZET status-dump `config.json` sitting in
  the identity dir, and a stale `option mode 'tunnel'` in `/etc/config/ziti`.

## Safety model for the live build

- ZET is **not in the clients' path** right now: clients egress direct lan->wan via `sta1`. So installing, enrolling,
  and reconfiguring ZET does **not** disturb client wifi.
- Only the deliberate **traffic-flip** (wildcard intercept + lan->ziti forward + fail-closed) redirects clients, and it
  is **gated on explicit user go**.
- Our SSH is to the **LAN IP 192.168.8.1**, which is router-input, not forwarded -- so it survives the flip.
- User constraint: **do not disrupt wifi comms without warning.** The home guest-subnet test (Phase 2) is last because
  moving the GL uplink onto guest requires wifi disruption.

## The runbook: docs/full-tunnel-travel-router.md

The reviewed ZET-gateway plan. Structure:

- **Part A (controller):** create the two configs, the service, the attribute-based Bind/Dial policies, and the two
  identities.
- **Part B (exit):** now a **cloud VPS** running ZET `run-host` (was Windows "sg3" in earlier drafts).
- **Part C (Slate):** install ZET, enroll, then firewall zone + lan->ziti forward, DNS, fail-closed, IPv6-off,
  cold-boot proof.

Notable sections:

- **3b** -- prove the wildcard exit actually forwards, from a throwaway dialer, before touching the Slate.
- **4.2b** -- prove the underlay stays direct with `ip route get` (controller + each edge router must be `dev wan`, not
  `dev ziti0`); roaming-safe hotplug re-pin for when the uplink gateway changes.
- **4.2c** -- pin the controller and any named edge routers in `/etc/hosts` so bootstrap never needs the tunneled
  resolver.
- **4.5** -- WAN-scoped DNS-leak reject, a `tcpdump` proof with ZET stopped, and a roaming-safe nftables fallback
  keyed off `ziti0`.
- **4.6** -- disable IPv6 on the Slate (largely already true on this device).
- **4.7** -- cold-boot proof: the box must come up unattended with the tunnel down and the DNS-leak rule live.

The plan was taken through **3 Mercurius review rounds** (blocking findings converged 3 -> 3 -> 1, all fixed). The
**/32 DHCP-lease client-isolation trick** was borrowed from Edward's guide (below).

## Edward's guide: openziti-edge-router-lan-gateway.md

An **all-in-one** ziti-router tproxy LAN gateway where **dial and bind are the same identity** and egress leaves the
box's **own WAN**. It does **not** meet the offload-to-a-remote-endpoint goal (traffic egresses locally, not at a
chosen remote exit), and it omits the `ip addr add <cidr> dev lo` control-channel risk documented above. Its **/32
DHCP-lease** client-isolation trick is worth reusing regardless of engine.

## Controller and object naming

- Controller: **ctrl.cdaws.clint.demo.openziti.org:8441**
- Exit: cloud **VPS**.
- Configs: `internet-intercept` (intercept.v1), `internet-host` (host.v1).
- Service: `internet-exit-svc` (role attribute `#internet-services`).
- Policies: `internet-bind` (Bind, `#internet-exit`), `internet-dial` (Dial, `#travel-clients`).
- Identities: `vps-exit-01` (`#internet-exit`), `travel-router-01` (`#travel-clients`).

## Phasing

- **Phase 1:** wildcard -> VPS. Success = a non-Ziti client on the GL wifi shows the **VPS public IP** via
  `curl ifconfig.me`.
- **Phase 2:** add a home-subnet service + a home endpoint to reach the isolated **guest** network. Deferred to last;
  needs wifi disruption to move the GL uplink onto guest. Note: the Phase 2 target must **not** be `192.168.1.0/24`,
  which is the current uplink subnet.
- **Future:** run controller/router + exit on a second GL box at home (two-box home/away).

## Current status and open items

- Exit is now the existing overlay edge router `ip-172-31-47-200-edge-router` (added to the `internet-bind` policy by
  `@name`), not a separate VPS -- fastest path. Egress = that EC2 box's public IP (~3.18.113.172, us-east-2). The
  `#internet-exit` attribute stays in the policy so a dedicated VPS or home exit slots in later just by tagging.
- Done: controller Part A (configs, service, policies, both identities); ER authorized to Bind `internet-exit-svc`;
  `travel-router-01` enrolled on the Slate. ZET is stopped with boot-autostart disabled.
- Mechanism PROVEN: with ZET started, a router-originated `curl` to 1.1.1.1 tunneled Slate -> overlay ->
  `ip-172-31-47-200-edge-router` -> internet ("ziti dial succeeded" in the ZET log). So the `host.v1` `0.0.0.0/0`
  wildcard forward IS honored at runtime by the ER, and NSS hardware offload did NOT bypass ziti0.
- To validate on-device still: DNS-upstream exclusion (#2400); ICMP-not-tunneled; userspace throughput.

## Incident: wildcard intercept black-holed client internet (recovered)

Starting ZET with the `0.0.0.0/1` + `128.0.0.0/1` intercept on the live router took out all client internet. Root
cause: ZET writes those CIDRs into the MAIN routing table as `dev ziti0`, so route selection diverts EVERY
internet-bound packet -- router-originated and forwarded client traffic alike -- onto ziti0. With no `lan->ziti`
firewall forwarding accept, the FORWARD chain dropped the client packets, black-holing them. The earlier assumption
"no lan->ziti forwarding means clients are untouched" was wrong: the global route diverts before the firewall, and the
firewall then drops.

- The control channel and the LAN (192.168.8.0/24) + uplink (192.168.1.0/24) stayed direct (more-specific routes), so
  the box was never hung -- a workstation that had roamed onto the upstream 192.168.1.x wifi simply lost its route to
  192.168.8.1.
- Recovery: rejoin the glinet's own LAN, `ssh root@192.168.8.1`, `/etc/init.d/ziti-edge-tunnel stop`. Routes cleared
  instantly; boot-autostart was disabled, so a power-cycle is also clean. The USG/UniFi shows the Slate as a wireless
  client (192.168.1.63 / 56:a9:85:eb:dc:96) -- a liveness signal, but UniFi cannot shell it.

## Corrected rollout for the client flip

There is no "router-only" wildcard test -- the intercept route is global. To flip clients safely:

1. Stage the ziti firewall zone (`device ziti0`) + `lan->ziti` forwarding (+ masq) BEFORE starting ZET, so intercepted
   client traffic is forwarded into the tunnel instead of dropped. A zone referencing a not-yet-existent ziti0 is
   inert until ZET creates the device.
2. Arm a dead-man's switch (a scheduled `ziti-edge-tunnel stop` in ~10 min) so a mistake self-recovers even if access
   is lost.
3. Start ZET; client traffic then tunnels via the ER. Verify a client `curl` shows the EC2 IP, then cancel the
   dead-man switch.

Alternatively prove first with a NARROW intercept (a single test destination) that cannot take the box down.

## Phase 1 result: PROVEN (non-Ziti client full-tunnel works)

The staged approach worked. Added the `ziti` firewall zone + `lan->ziti` forwarding (masq on), started ZET, and a
non-Ziti client on the glinet wifi egresses through the overlay at the chosen exit:

- Both a router-origin request and a real client (the SG4 workstation on 192.168.8.x, no OpenZiti software) return
  `ip=3.18.113.172` (`colo=CMH`, Ohio) from `https://1.1.1.1/cdn-cgi/trace` -- i.e. glinet wifi client -> ziti0 ->
  overlay -> `ip-172-31-47-200-edge-router` -> internet, egressing at the EC2 box.
- `masq=1` on the ziti zone (client src rewritten to 100.64.0.1) made forwarded client traffic take the same proven
  path as router-origin traffic. This is the key that made the staged flip carry client traffic instead of dropping it.

Dead-man caveat: `setsid /tmp/ziti-deadman.sh &` did NOT leave a trackable/persistent process on busybox (`$!` caught
the wrong pid; `pgrep` found nothing), so the 10-minute auto-stop never armed. It did not matter here, but for a
reliable dead-man use `at`, a cron one-shot, or `( sleep N; stop ) &` with the subshell pid recorded. Recovery remains
via glinet-LAN `/etc/init.d/ziti-edge-tunnel stop` or reboot (boot-autostart is disabled).

Remaining hardening before this is a daily-driver (all deferred, deliberate steps): DNS-resolve-as-home (egress is
Ohio but DNS still resolves via the local uplink, so geo/CDN may mismatch -- section 4.4), fail-closed + the WAN
DNS-leak rule (4.5), controller-by-IP pin (4.2c), cold-boot proof (4.7). Then Phase 2 (reach the isolated home guest
subnet).

## Egress options and the home-exit switch

- Proven exit = the EC2 edge router (Ohio) -- good for proving the mechanism, wrong location for home-as-home.
- For a real home vantage point, move the Bind to a home endpoint that egresses from the home ISP. Candidate: an M1 mini at home
  running `ziti-edge-tunnel` in a HOSTING mode (`run` or `run-host`). The macOS Desktop Edge app is client-only and
  will NOT host -- it must be the ziti-edge-tunnel CLI.
- Safe switch (no black-hole): ADD the exit to the `internet-bind` policy while KEEPING the ER, confirm the exit
  registers a terminator (`ziti edge list terminators 'service.name="internet-exit-svc"'`), THEN remove the ER. If the
  exit never registers a terminator, it is not hosting and removing the ER first would black-hole all client traffic.
- Exit candidates tried: (1) M1 mini -- rejected, its ziti service restarts unreliably. (2) sg3 Windows box running
  ZDEW -- tagged its identity `ClintSG3` with `#internet-exit`. CORRECTION to an earlier note: ZDEW DOES host --
  after a manual disable/enable of the identity in the GUI, `ClintSG3` registered a terminator and became the exit
  (this is where the home egress `67.246.244.61` came from). But it is UNRELIABLE: it needs the manual nudge to
  register, and it DROPS the terminator on reboot/uplink-change, silently falling back to the ER (Ohio) -- observed
  as `curl eth0.me` returning `3.18.113.172` again after a reboot. So ZDEW-hosting works but is not set-and-forget.
  The reliable Windows exit is the `ziti-edge-tunnel.exe` CLI in `run-host` mode with its own identity `sg3-exit`,
  wrapped as an nssm auto-start service (coexists with ZDEW). Egress then = the sg3 home ISP IP, durably.
- Stale exit authorizations accumulate as you experiment (m1mini-exit, vps-exit-01, ClintSG3 all left tagged
  `#internet-exit` or Bind-authorized). Since `internet-bind` matches `#internet-exit`, ANY tagged identity that comes
  online becomes an exit and load-balances (cost 0) -- inconsistent geo. Keep exactly one intended exit tagged; untag
  the rest (`ziti edge update identity <name> --role-attributes ""`) and drop the ER `@name` once the real exit is
  reliable.

## Home-egress PROVEN via sg3

With `ziti-edge-tunnel.exe run-host` up on sg3 (identity `sg3-exit`, tagged `#internet-exit`), a non-Ziti client on
the glinet wifi egresses from the **home ISP IP** `67.246.244.61` (Charter/Rochester; colo ORD/Chicago) -- confirmed by
`curl https://1.1.1.1/cdn-cgi/trace` and `curl eth0.me` from the SG4 workstation, no longer the EC2 exit
`3.18.113.172`. This is the full project goal: appear to be at home, from a device with no OpenZiti software, behind a
wifi we operate.

Traceroute confirms the datapath: from the home LAN directly, `tracert eth0.me` walks the full Charter path
(Rochester -> Chicago -> Cloudflare); from behind the glinet the same trace collapses to `192.168.8.1` -> destination
with every ISP hop gone -- the L4-overlay signature (opaque underlay, ICMP not carried) -- while the egress IP stays
the home `67.246.244.61`.

- Ziti preferred sg3 automatically: its `edge` terminator has cost 0 vs the ER's `tunnel` terminator cost 4, so
  traffic chose the home exit with both bound -- no policy change required to route through home.
- Reliability nuance: `run-host` needed a disable/enable before it registered its terminator. Wrap it with nssm (or
  sc) as a Windows service so it survives reboots and re-registers on its own.
- Cleanup for home-only egress: drop the ER from the Bind policy -- `ziti edge update service-policy internet-bind
  --identity-roles '#internet-exit'` -- leaving only `sg3-exit`.

## Incident 2: uplink change with the intercept live (roaming bootstrap gap)

Switched the glinet's repeater uplink from stargate (192.168.1.x) to an isolated guest SSID WITHOUT stopping ZET
first. Result: no internet on guest (and on an iot SSID tried next), then the box wedged. Root cause: with the
`0.0.0.0/1` intercept live, moving to a new network forces ZET to re-reach the controller over that network, but the
wildcard catches its own control channel before the tunnel is up, so the tunnel cannot bootstrap and all traffic
black-holes. This is the roaming variant of Incident 1. Recovery: reboot (boot-autostart disabled, so it comes up
clean); user reverted the uplink to stargate.

Correct order for the guest/foreign-network test:
1. First isolate cause with ZET OFF -- confirm the guest/iot SSID actually provides outbound internet at all.
2. Apply the bootstrap hardening BEFORE switching uplinks: pin the controller + edge routers in `/etc/hosts` (4.2c)
   so ZET can resolve/reach them without the tunnel, and a hotplug hook that re-pins the underlay exclusion to the
   current gateway on every WAN bring-up (4.2b). Only then is a wildcard intercept safe across an uplink change.
3. Or the simple path: stop ZET, switch uplink, verify controller reachability on the new network, then start ZET.

### Confirmation: fresh hardened start on the foreign network WORKS

On the isolated PPIoT uplink (glinet `192.168.102.135` via gateway `192.168.102.1` on `sta0`, a network that cannot
even ping sg3 at `192.168.1.147`), a FRESH ZET start with the `/etc/hosts` controller pin bootstrapped cleanly:
`ip route get 3.18.113.172` -> `via 192.168.102.1 dev sta0` (exclusion correctly re-derived on the new gateway),
`1.1.1.1` -> `ziti0`, and a client egressed the home IP `67.246.244.61`. This proves portability -- the travel router
works from a genuinely foreign/isolated network -- and confirms by contrast that Incident 2 was the live-uplink-change
leaving a stale exclusion (host-route via the OLD gateway) while the wildcard intercept swallowed ZET's own reconnect.
No logs exist from the incident itself (box was wedged); this fresh-start success is the confirming experiment, not a
log finding.

Dead-man reliability: BOTH `setsid ... &` and `nohup sh -c '...' &` launched from an ssh-invoked script failed to
leave a persistent process (`kill -0` on the captured pid fails), so the 600s auto-stop never armed either time.
Manual `/etc/init.d/ziti-edge-tunnel stop` over LAN SSH is the working recovery. For a real dead-man use cron, `at`,
or a procd one-shot rather than a backgrounded subshell.

## Bonus: home-LAN reach, not just internet egress

A client behind the glinet reaching a home-LAN host (sg3 at `192.168.1.147`) traces in 2 hops (glinet -> destination):
the traffic is intercepted (`192.168.1.147` is inside `128.0.0.0/1`), tunneled to the sg3 exit, and sg3 forwards it
onto its own LAN via `host.v1` (`allowedAddresses 0.0.0.0/0` covers `192.168.1.0/24`). So the single wildcard exit
gives full home-LAN access as well as internet egress -- the Phase-2 "reach my other network" goal is met by the same
service, as long as the exit sits on that LAN. This works only while the exit is up; via flaky ZDEW it drops on
reboot/roam and falls back to the ER.

## luci-app-ziti bugs found on-device

1. The rpcd backend `/usr/libexec/rpcd/ziti` ships **0644 (non-executable)**, so rpcd never registers the `ziti`
   object -> LuCI Status tab shows `RPCError -32000: Object not found` and the Identities tab is empty. Fix live:
   `chmod 0755 /usr/libexec/rpcd/ziti` + `/etc/init.d/rpcd restart`. Repo fix: the Makefile must install it 0755.
2. `status`/`list_identities` build the identity list from **UCI `config identity` sections, not the identity dir**.
   CLI-enrolled identities (`ziti-edge-tunnel enroll`, which only writes the `.json`) therefore never appear in the UI
   even though ZET loads them from `/etc/ziti/identities/`. Repo fix: rpcd should enumerate the dir (ZET's actual
   source of truth). Workaround: add a matching `config identity` UCI section -- but committing it triggers a ZET
   reload (service trigger on `/etc/config/ziti`), a brief client blip.

## full|split tunnel toggle -- design

OpenZiti is service-based, so the toggle must control WHICH services ZET intercepts, not just the firewall (a
wildcard `0.0.0.0/1` intercept on ziti0 captures everything regardless of firewall). Cleanest local, buildable design:

- Two enrolled identities on the glinet: `travel-full` (authorized to Dial the wildcard `internet-exit-svc`) and
  `travel-split` (authorized only for narrow home services / specific CIDRs).
- Full: enable `travel-full.json`, disable `travel-split` (rename to `.json.disabled`), firewall lan->ziti +
  fail-closed, reload ZET.
- Split: enable `travel-split`, disable `travel-full`, firewall lan->wan direct (plus lan->ziti for the narrow
  routes), reload ZET.
- luci-app-ziti: add `option tunnel_mode 'full'|'split'`, a LuCI switch, and an rpcd action that flips the identity
  enable-state (reusing the existing enable-by-rename mechanism) + the firewall + reloads ZET.

This is a focused build (LuCI view + rpcd method + firewall logic + the two controller-side service/identity setups +
on-device test), not an inline change.

IMPLEMENTED in luci-app-ziti (PKG_RELEASE 3; pending build + on-device test):
- `root/usr/libexec/rpcd/ziti`: `get_tunnel_mode` + `set_tunnel_mode` (identity enable-by-rename `.json`/`.json.disabled`
  + ziti firewall zone/`lan->ziti` forwarding + `lan->wan` fail-closed toggle + ZET restart + firewall reload).
- `htdocs/.../view/ziti/tunnel.js`: the Tunnel Mode view (full/split buttons + full/split identity fields).
- `menu.d/luci-app-ziti.json`: "Tunnel Mode" tab; `acl.d/luci-app-ziti.json`: grants for the new methods + firewall uci
  and `/etc/init.d/firewall reload` exec.
- `Makefile`: now `chmod 0755` the rpcd backend on install -- FIXES the RPCError-32000 bug (it shipped 0644).
Full mode relies on the 4.2c controller `/etc/hosts` pin for a clean fresh-start bootstrap (fail-closed removes
`lan->wan`, so a failed bootstrap would black-hole -- the pin is what makes the restart reconnect cleanly).
Bug 2 FIXED: rpcd `status`/`list_identities` now enumerate the identity DIR via `build_identities_json` (name from
basename, `enabled` from `.json` vs `.json.disabled`), filtering out ZET's runtime `config.json` status file. This
shows CLI-enrolled identities and reflects the toggle's enable-by-rename. The Tunnel Mode view uses this list to offer
the full/split identities as dropdowns.

Build/deploy notes:
- `tools/build-sdk.ps1` fails on Windows Docker Desktop at `docker run` with "invalid volume specification:
  'D:\...\package:/feed:ro'" -- the host path is passed with backslashes, so Docker mis-splits on the colons. Fix:
  convert host paths to forward slashes for the `-v` specs (e.g. `$FeedPath -replace '\\','/'`). The image build
  itself succeeds; only the volume-mounted `docker run` step fails. (The `.sh` under Git-Bash has the mirror problem:
  `MSYS_NO_PATHCONV=1` leaves the build context as `/d/...` which Windows Docker cannot find.)
- For TESTING, luci-app-ziti is arch `all` (pure files), so the changed files were deployed straight to the live
  glinet (scp root/ + htdocs/ files to their target paths, chmod 0755 the rpcd backend, `/etc/init.d/rpcd restart`,
  clear `/tmp/luci-indexcache*`). The Tunnel Mode tab + `get_tunnel_mode`/`set_tunnel_mode` verified live. A real
  feed `.ipk` build still needs the build-sdk path bug fixed.

## luci-app-ziti: future enhancements (captured, not now)

- Live per-identity status: the Status/Identities list still stubs `controller` = "" and `status` = "unknown". Wire
  these from the identity JSON (controller/ztAPI URL) and ZET's runtime dump (config.json in the identity dir has
  Loaded/Active per identity) so the UI shows real connection state instead of "unknown".
- Controller-assisted enrollment: rather than hand-pasting JWTs, let the plugin authenticate to the controller
  (OIDC / an admin token) and CREATE the identities + policies for the user directly from the UI. Big usability win.
- Failing that, surface the exact `ziti` CLI commands the user must run (the Part A block: configs, service,
  attribute policies, identities) directly in the UI so they can copy-paste them.
- Tunnel Mode view: replaced per-field help with a Documentation link (placeholder gh-pages URL); active mode is the
  highlighted/disabled button. Consider merging Tunnel Mode into Settings if two config tabs feels redundant.
- ZET version picker in Settings. Framing: end users NEVER build -- the PROJECT builds each arch in CI and publishes
  signed ipks to the feed, and opkg auto-selects the device's arch subtree (no arch choice in the UI; "download the
  right thing" is transparent). The manual build/repack/sideload done for 1.18.1 was only a maintainer workaround for
  broken local Docker. So the only missing piece is VERSION selection, which needs (a) the feed to RETAIN multiple
  versioned ipks + a manifest (it keeps latest-per-arch today), and (b) a UI + rpcd action running
  `opkg install ziti-edge-tunnel=<ver>` then restart. Full arbitrary version-pick is the larger build (feed retention
  + manifest).
- IMPLEMENTED: Settings -> Updates section (`check_update` + `upgrade_zet` rpcd methods). "Check for updates" shows the
  source feed URL (proving GitHub-only), signature-verified status, installed vs newest-in-feed, and offers Upgrade
  only when `opkg list-upgradable` reports a genuinely newer feed version (no downgrade). Upgrade re-verifies then
  `opkg install ziti-edge-tunnel` + restart.

## Signing / authenticity of feed packages

The feed IS usign-signed (publish-feed.sh: `usign -S -m Packages -x Packages.sig`) and the project pub key is imported
to `/etc/opkg/keys/`. BUT GL.iNet ships `/etc/opkg.conf` WITHOUT `option check_signature`, so opkg does not enforce it,
and enabling it globally BREAKS `opkg update` because GL's own `glinet_gli_pub` feed has no `Packages.sig` (opkg
check_signature is global, not per-feed; observed exit 1). So instead the update rpcd verifies the openziti feed
EXPLICITLY: curl `Packages` + `Packages.sig`, `usign -V -p <imported key> -m Packages -x Packages.sig` (returns OK
on-device), and REFUSES to upgrade if it does not verify. This proves project authenticity for our package without
touching the global setting or breaking GL feeds. opkg then validates the installed ipk's sha256 against the verified
index. check_update currently reports installed 1.18.1-1 (sideloaded) ahead of the feed's 1.15.1-2, so upgradable=false
until CI publishes 1.18.1 to the feed.
- UI build stamp + caching gotcha: LuCI serves view JS at version-stamped URLs that DO NOT change when you scp a new
  view, so a plain F5 keeps the old JS -- and it's per-file, so hard-reloading on one tab does not refresh another
  tab's JS. This caused hours of "the UI is chopped" confusion (Identities/Tunnel looked broken while the device had
  the correct files). Reliable dev workaround: DevTools -> Network -> Disable cache, then reload. To make staleness
  obvious, every view shows a `UI_BUILD` stamp next to its title; the canonical dev deploy (scratchpad
  deploy-luci.sh) auto-injects a fresh monotonic UTC timestamp (`ui YYYYMMDD-HHMMSS`) into all views via sed before
  scp -- no manual bumping. All four tabs are functional once freshly loaded: Status/Identities list from the
  identity dir with controller (ztAPI) + status (active/disabled/stopped); Tunnel Mode shows current mode, the
  loaded-now identity, and identity dropdowns; Settings has the signed Update check.

## Version bump: ziti-edge-tunnel 1.15.1 -> 1.18.1

`package/ziti-edge-tunnel/Makefile`: PKG_VERSION 1.18.1, PKG_RELEASE 1, PKG_HASH
`9f780b7d46da7467941f800966a39a634b65b02bc36bfb953ffd3784ca6659ff` (sha256 of the codeload tarball at
refs/tags/v1.18.1, verified by download). BUILT + INSTALLED: compiled cleanly (3-version jump is fine; `llhttp`
stayed 9.4.1, no bump needed), repacked to `aarch64_cortex-a53_neon-vfpv4`, and opkg-upgraded on the glinet
1.15.1-2 -> 1.18.1-1 (binary reports v1.18.1). ACTIVATED via the LuCI Status Restart button; the running daemon is
now 1.18.1 and a client still egresses the home IP 67.246.244.61 (full-tunnel intact). The live `/etc/config/ziti`
was preserved (opkg parked its default at `/etc/config/ziti-opkg`). Transient `err=-14` per-connection resets appeared
in the log during the reconnect blip and are benign (egress works).

WORKING LOCAL-BUILD METHOD (since Windows Docker bind-mounts fail): build in WSL. `ssh cdwsl` shares the same Docker
daemon; rsync the repo from `/mnt/d/...` to a native path `/mnt/wsl/git/github/openziti/ziti-openwrt` (use
`rsync -rlD --no-times --omit-dir-times --no-perms` -- `/mnt/wsl` rejects utime/chmod, so `-a` fails with code 23),
then run `bash tools/build-sdk.sh -p <pkg> -t aarch64_cortex-a53` there (Linux paths, bind-mounts work). Repack the
ipk with publish-feed.sh's control-rewrite, write it to `/mnt/d/.../build/` so the Windows host can scp it to the
device. CLAUDE.md key-versions doc still says 1.15.1
(symlinked into dotagents; not edited here).

Local Docker bind-mount does not work on this Windows box regardless of `-v` path form: `D:\...` and `D:/...` are
rejected ("invalid volume specification"), and `//d/...`, `/mnt/d/...`, `/run/desktop/mnt/host/d/...` all mount an
EMPTY /feed (docker run exits 0 but the package tree is not visible). Root cause is Docker Desktop drive-sharing /
WSL2 integration for D:, not the scripts. Changing build-sdk.ps1 to forward-slash paths did not help. So local builds
need Docker Desktop file-sharing fixed for D:; otherwise build via CI (Linux) where bind-mounts are native. This
blocks BOTH the ZET 1.18.1 build and a distributable luci-app-ziti .ipk locally (luci-app-ziti was deployed by direct
file copy instead).

## Feature request: LuCI full-tunnel toggle (glinet UI)

Wanted: a toggle in the glinet UI (luci-app-ziti) for "tunnel everything" vs "tunnel only the services you need"
(full vs split tunnel). Full-tunnel = dial the wildcard intercept service + add the `ziti` firewall zone + `lan->ziti`
forwarding (masq); split = only named services intercepted, no forced default route and no blanket `lan->ziti`. The
manual steps proven here (stage firewall zone + forwarding, then start ZET) are exactly what the toggle should
automate -- with the incident's lesson baked in: never leave a wildcard intercept live without the forwarding rule,
and give a one-click OFF that stops ZET and drops the zone/forwarding.
