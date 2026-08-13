# Blog series idea: a zero-trust travel router with OpenZiti

Working notes for a blog post or short series about turning a GL.iNet Slate 7 (GL-BE3600) into a full-tunnel travel
router on OpenZiti. Source material: `docs/travel-router-buildlog.md`, `docs/full-tunnel-travel-router.md`,
`docs/router-compatibility-matrix.md`.

The through-line: a device with NO OpenZiti software on it -- your phone, a work laptop, a smart TV -- joins a wifi you
run and behaves as if it is sitting on your home network, egressing from your home ISP, from anywhere in the world.
That is the hook. The overlay is invisible to the client; the travel router does all the work.

## Series arc (7 parts)

### Part 1 -- "Appear at home from anywhere: why a travel router, and why not a VPN"
- Hook: your home NAS, your internal dashboards, and the bank that flags foreign logins all behave as if you never
  left the couch -- from a hotel, with no VPN app on any device.
- Beat: the goal and the shape of the solution. What a travel router is, what "full tunnel" means here, and why
  OpenZiti is a strange but powerful choice: it is an application-layer (L4) overlay, not an IP/packet VPN. That
  distinction drives everything later (TCP/UDP only, no ICMP, the exit opens its own sockets and self-NATs).
- Show: the topology diagram (client -> GL wifi -> ziti0 -> overlay -> home/cloud exit -> internet). A one-paragraph
  contrast table: WireGuard/OpenVPN vs OpenZiti here.
- Aha: you are not building a tunnel between two boxes; you are publishing "the internet" as a service and dialing it.

### Part 2 -- "Learn from my pain: how I bricked my own router (twice), live"
- Hook: I ran one command and every device on the wifi lost the internet -- while I was the one on the wifi.
- Beat: the failure tour. The wildcard-intercept black-hole (0.0.0.0/1 routes go in the MAIN table, divert ALL
  forwarded client traffic to ziti0, and with no lan->ziti forwarding rule they are dropped). The roaming deadlock
  (changing the uplink with the intercept live means ZET cannot re-reach the controller -- it catches its own control
  channel before the tunnel exists). The exit-node dead ends: the M1 mini whose service kept restarting, and Ziti
  Desktop Edge for Windows which will host a service only after a manual disable/enable and then drops it on reboot.
  And the one that reshaped the design: the exit terminator dying MID-SESSION -- the tunnel stayed up, the router kept
  routing every client into it, and all traffic black-holed until a manual stop (the automatic fix is Part 4).
- Show: the exact black-hole sequence and the recovery (LAN-side SSH survives because it is not forwarded; reboot is
  clean because boot-autostart was disabled). The "connected but no internet" symptom on an isolated network.
- Aha: with a global wildcard intercept there is no "just test it" -- stage the firewall and a controller pin first,
  or you take yourself offline. Fail loud, fail open, keep an out-of-band way in.

### Part 3 -- "The architecture that worked: ZET, host.v1, and proving it with fabric events"
- Beat: the design that survived. ZET (the C tunneler, TUN + lwIP) as the gateway on the Slate -- NOT the ziti-router
  tproxy, because the router makes each intercept CIDR local via `ip addr add <cidr> dev lo`, so 0.0.0.0/0 swallows
  the box. The split-default intercept (0.0.0.0/1 + 128.0.0.0/1). The `host.v1` forward-to-original-destination exit
  that self-NATs (no New-NetNat/ip_forward needed). Fail-closed (drop lan->wan) plus the WAN-scoped DNS-leak rule and
  the /etc/hosts controller pin that make it survive a cold boot on a foreign network.
- Show: the working `ziti` CLI (configs, service, attribute-based Bind/Dial policies, identities) -- see the parameter
  reference doc. The proof: `ziti fabric stream events` circuits tagged clientId=travel-router, hostId=exit,
  serviceId=internet-exit-svc, and the `connect` event showing the exit's home source address.
- Aha: attribute-based policies mean you add a new traveling device by tagging an identity -- no policy edits ever.

### Part 4 -- "Never black-hole the wifi: the resilience watchdog and fail-open"
- Hook: at a cowork desk the exit died mid-session and every client lost the internet -- the router happily kept
  routing everyone into a tunnel that no longer went anywhere. Nobody wants to debug that from a coffee shop.
- Beat: the hard rule -- the wifi, and especially DNS, must NEVER stop; every failure path falls OPEN to plain direct
  internet, never closed into a black-hole. Two safeguards enforce it. A boot-time preflight gate: before starting the
  tunnel, refresh and pin every controller (ztAPI + ztAPIs[]) in /etc/hosts and prove one is reachable over the current
  uplink -- if not, do not install the wildcard routes at all, so a dead controller or captive portal cannot black-hole
  the wifi. A continuous watchdog running as its OWN procd service (so its own teardown cannot kill it): whenever the
  wildcard /1 intercept is actually live on ziti0, it probes egress THROUGH the tunnel every few seconds and, after a
  few consecutive failures, tears the tunnel down, restores direct internet, and stays open.
- Show: the log of the mid-session death and the automatic fall-open ~50s later; the LuCI "Last boot check" line; the
  watchdog config (probe targets, interval, failure count). The kill test: stop the exit, watch direct internet return
  on its own with nobody touching the box.
- Aha: a full-tunnel router is only safe if it knows how to give up. Trigger on the actual /1 route, not a config flag,
  and it protects you no matter how full-tunnel got turned on.

### Part 5 -- "DNS that resolves as-at-home, without ever breaking DNS"
- Hook: your home name server answers as if you were on the couch -- a home hostname resolves to its home LAN IP --
  from a foreign wifi, and if the tunnel drops, normal browsing DNS never even hiccups.
- Beat: the constraint that shaped everything -- DNS failures are the most visible outage there is, so general
  resolution must never depend on the tunnel. dnsmasq keeps its own direct default resolver, untouched. We only ADD
  per-domain forwarding of chosen domains (your overlay suffix, your home DHCP domain) to ZET's embedded resolver; ZET
  answers Ziti service names with synthetic IPs and forwards everything else to a home resolver -- a pi-hole -- reached
  OVER the tunnel, so home names resolve from the home vantage. Tunnel down? Only those domains fail; all other DNS is
  unaffected. No single point of failure, no coupling to the tunnel's up/down state.
- Show: three lookups from a client behind the router -- a home name resolving to its home LAN IP, a Ziti service name
  resolving to a synthetic 100.64.x, and a public name resolving normally via the untouched default.
- Aha (and the best war story): ZET's resolver does not live where you expect. It sits at the .2 of the DNS range
  (100.64.0.2, not .1 -- .1 is the tun's own local address and answers nothing) and is reached by routing INTO the tun.
  dnsmasq was squatting that address until we told it to let go. Found the hard way, live.

### Part 6 -- "Making it usable: a LuCI app, a signed feed, and self-update"
- Beat: turning a pile of SSH commands into something a human operates. The luci-app-ziti tabs (Status with a
  "Last boot check" line and a start-at-boot toggle, Identities, Tunnel Mode with a full/split toggle that flips
  identities + firewall, and Settings for the signed self-update, the resilience-watchdog tuning, and the OpenZiti DNS
  domains + upstream). The
  packaging: an OpenWRT SDK build in Docker, a usign-signed opkg feed on GitHub Pages, and why the device verifies the
  feed signature explicitly (GL.iNet ships opkg with check_signature off, and turning it on globally breaks GL's own
  unsigned feed). The CI that rebuilds + republishes on push, and a scheduled job that tracks upstream ZET releases
  and opens a bump PR.
- Show: the Tunnel Mode tab; the Updates panel proving "signed by the project" + GitHub-only source; the
  check-upstream-versions workflow.
- Aha: the trust anchor is the feed signature, not the transport -- prove provenance, do not just trust the URL.

### Part 7 -- "Will it run on your router? Portability and the compatibility matrix"
- Beat: what hardware works, the OpenWRT 23.05 line and the libopenssl ABI constraint, the GL.iNet QSDK arch-label
  repack (aarch64_cortex-a53 -> aarch64_cortex-a53_neon-vfpv4), and the one-line signed-feed install. The NSS
  hardware-offload caveat on QSDK devices.
- Show: the matrix table (arch | example devices | ZET/router/luci | flash/RAM | notes) and the Tier 1-4 device tiers.
- Aha: no special equipment -- a supported router plus one exit endpoint you already have (a VPS, a home box, or an
  existing edge router).

## Single standalone post (if you only write one)

Title: "I turned a $100 travel router into a zero-trust home gateway (and bricked it twice first)."
Shape: lead with the payoff (2-hop traceroute + home IP from a hotel), then the one-paragraph why-not-a-VPN, then the
three gotchas that will bite anyone, then the minimal working recipe, then the two things that make it livable -- it
never black-holes your wifi (fails open) and it resolves your home names as-at-home without touching general DNS --
then "here is the LuCI app so you do not have to type any of it." Links out to the deeper docs for the full CLI.

## Strongest visual moments

- The traceroute collapse: from the home LAN, `tracert eth0.me` walks the full home-ISP path (multiple ISP hops to
  Cloudflare); from behind the travel router the SAME trace collapses to two hops (gateway -> destination) because the
  overlay underlay is opaque and ICMP is not carried. Side-by-side screenshot -- this one image tells the whole story.
- `curl ifconfig.me` / `curl eth0.me` from a non-Ziti client on the travel wifi returning the HOME public IP, run from
  a demonstrably foreign network.
- `ziti fabric stream events`: live `circuit created` / `connect` lines with the client, exit, and service tags -- the
  overlay proving itself in real time.
- The Tunnel Mode toggle flipping full <-> split, and the signed Updates panel showing "verified (signed by the
  project)".
- The watchdog fall-open: kill the exit and screen-record the router log tearing the tunnel down and restoring direct
  internet on its own ~50s later -- the "it fixes itself" moment.
- The three DNS lookups side by side from one client: a home hostname -> its home LAN IP, a Ziti service name -> a
  synthetic 100.64.x, a public name -> resolved normally -- proof that home-vantage DNS and untouched general DNS
  coexist.

## Production notes

- Use the `ziti-slide` skill for OpenZiti-branded title slides, the architecture diagram (dark navy, teal/blue accent,
  floating terminal cards), and a video thumbnail if any part becomes a video. The topology and the failure-mode
  diagrams are the two worth rendering in that style.
- Keep code blocks parameterized (controller, service, identity names) and point at the CLI reference doc so the post
  stays readable while the copy-paste lives in the repo.
- Tone for Part 2: own the failures plainly -- the black-hole and the roaming deadlock are the most instructive part
  of the whole build and make the best story.
