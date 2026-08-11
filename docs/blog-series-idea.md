# Blog series idea: a zero-trust travel router with OpenZiti

Working notes for a blog post or short series about turning a GL.iNet Slate 7 (GL-BE3600) into a full-tunnel travel
router on OpenZiti. Source material: `docs/travel-router-buildlog.md`, `docs/full-tunnel-travel-router.md`,
`docs/router-compatibility-matrix.md`.

The through-line: a device with NO OpenZiti software on it -- your phone, a work laptop, a smart TV -- joins a wifi you
run and behaves as if it is sitting on your home network, egressing from your home ISP, from anywhere in the world.
That is the hook. The overlay is invisible to the client; the travel router does all the work.

## Series arc (5 parts)

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
- Show: the exact black-hole sequence and the recovery (LAN-side SSH survives because it is not forwarded; reboot is
  clean because boot-autostart was disabled). The "connected but no internet" symptom on an isolated network.
- Aha: with a global wildcard intercept there is no "just test it" -- stage the firewall and a controller pin first,
  or you take yourself offline. Fail loud, fail closed, keep an out-of-band way in.

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

### Part 4 -- "Making it usable: a LuCI app, a signed feed, and self-update"
- Beat: turning a pile of SSH commands into something a human operates. The luci-app-ziti tabs (Status, Identities,
  Tunnel Mode with a full/split toggle that flips identities + firewall, Settings with a signed self-update). The
  packaging: an OpenWRT SDK build in Docker, a usign-signed opkg feed on GitHub Pages, and why the device verifies the
  feed signature explicitly (GL.iNet ships opkg with check_signature off, and turning it on globally breaks GL's own
  unsigned feed). The CI that rebuilds + republishes on push, and a scheduled job that tracks upstream ZET releases
  and opens a bump PR.
- Show: the Tunnel Mode tab; the Updates panel proving "signed by the project" + GitHub-only source; the
  check-upstream-versions workflow.
- Aha: the trust anchor is the feed signature, not the transport -- prove provenance, do not just trust the URL.

### Part 5 -- "Will it run on your router? Portability and the compatibility matrix"
- Beat: what hardware works, the OpenWRT 23.05 line and the libopenssl ABI constraint, the GL.iNet QSDK arch-label
  repack (aarch64_cortex-a53 -> aarch64_cortex-a53_neon-vfpv4), and the one-line signed-feed install. The NSS
  hardware-offload caveat on QSDK devices.
- Show: the matrix table (arch | example devices | ZET/router/luci | flash/RAM | notes) and the Tier 1-4 device tiers.
- Aha: no special equipment -- a supported router plus one exit endpoint you already have (a VPS, a home box, or an
  existing edge router).

## Single standalone post (if you only write one)

Title: "I turned a $100 travel router into a zero-trust home gateway (and bricked it twice first)."
Shape: lead with the payoff (2-hop traceroute + home IP from a hotel), then the one-paragraph why-not-a-VPN, then the
three gotchas that will bite anyone, then the minimal working recipe, then "here is the LuCI app so you do not have to
type any of it." Links out to the deeper docs for the full CLI.

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

## Production notes

- Use the `ziti-slide` skill for OpenZiti-branded title slides, the architecture diagram (dark navy, teal/blue accent,
  floating terminal cards), and a video thumbnail if any part becomes a video. The topology and the failure-mode
  diagrams are the two worth rendering in that style.
- Keep code blocks parameterized (controller, service, identity names) and point at the CLI reference doc so the post
  stays readable while the copy-paste lives in the repo.
- Tone for Part 2: own the failures plainly -- the black-hole and the roaming deadlock are the most instructive part
  of the whole build and make the best story.
