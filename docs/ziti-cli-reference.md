# ziti CLI + device command reference (full-tunnel travel router)

Every command needed to stand up the full-tunnel travel router, parameterized. Placeholders are in `<ANGLE>` with the
values we actually used shown as the example. Cross-reference: `docs/full-tunnel-travel-router.md` (the runbook) and
`docs/how-it-works-and-gotchas.md` (the why).

Placeholders:

| Placeholder | Example used | Meaning |
|---|---|---|
| `<CONTROLLER>` | `ctrl.cdaws.clint.demo.openziti.org:8441` | controller edge API |
| `<SERVICE>` | `internet-exit-svc` | the wildcard (full-tunnel) service |
| `<SVC_ATTR>` | `internet-services` | service role attribute |
| `<CLIENT_ROLE>` | `#travel-clients` | identities allowed to Dial |
| `<EXIT_ROLE>` | `#internet-exit` | identities allowed to Bind/host |
| `<TRAVEL_ID>` | `travel-router-01` | the travel router's client identity |
| `<EXIT_ID>` | `vps-exit-01` / `sg3-exit` | the exit identity |
| `<ER_NAME>` | `ip-172-31-47-200-edge-router` | an existing edge router (fallback exit) |
| `<HOME_SUBNET>` | `192.168.50.0/24` | a home LAN you want reachable in split mode |
| `<EXIT_PUBLIC_IP>` | `67.246.244.61` (home) / `3.18.113.172` (EC2) | the exit's egress IP (your proof target) |

Windows/PowerShell gotcha: long JSON args get line-wrapped by the console and corrupt the command. Put the JSON in a
file and pass `((Get-Content -Raw .\file.json).Trim())`, as shown below.

## 1. Log in

```
ziti edge login <CONTROLLER> -u <USER> -p <PASSWORD> -y
```

## 2. Part A -- create the service + policies (on the controller)

Write the two config bodies to files first (avoids the PowerShell wrap bug):

`internet-intercept.json` (IPv4-only split-default -- wins over the OS default route without clobbering it):

```json
{"protocols":["tcp","udp"],"addresses":["0.0.0.0/1","128.0.0.0/1"],"portRanges":[{"low":1,"high":65535}]}
```

`internet-host.json` (forward each flow to the destination the client originally asked for):

```json
{"forwardProtocol":true,"allowedProtocols":["tcp","udp"],"forwardAddress":true,"allowedAddresses":["0.0.0.0/0"],"forwardPort":true,"allowedPortRanges":[{"low":1,"high":65535}]}
```

```powershell
# configs
ziti edge create config internet-intercept intercept.v1 ((Get-Content -Raw .\internet-intercept.json).Trim())
ziti edge create config internet-host      host.v1      ((Get-Content -Raw .\internet-host.json).Trim())
# service, tagged with a role attribute
ziti edge create service <SERVICE> -c internet-intercept,internet-host -a <SVC_ATTR>
# attribute-based policies: exit hosts (Bind), travel clients use (Dial)
ziti edge create service-policy internet-bind Bind --service-roles '#<SVC_ATTR>' --identity-roles '<EXIT_ROLE>'   --semantic AnyOf
ziti edge create service-policy internet-dial Dial --service-roles '#<SVC_ATTR>' --identity-roles '<CLIENT_ROLE>' --semantic AnyOf
# edge-router reachability -- SKIP if you already have blanket '#all' ER policies
ziti edge create edge-router-policy         internet-erp  --identity-roles '<EXIT_ROLE>,<CLIENT_ROLE>' --edge-router-roles '#all'
ziti edge create service-edge-router-policy internet-serp --service-roles '#<SVC_ATTR>'                --edge-router-roles '#all'
# identities -> one-time JWTs (pre-tagged, so the policies above already authorize them)
ziti edge create identity <EXIT_ID>   -a internet-exit   -o <EXIT_ID>.jwt
ziti edge create identity <TRAVEL_ID> -a travel-clients  -o <TRAVEL_ID>.jwt
# sanity check
ziti edge policy-advisor services -q
```

Note: on some `ziti` builds `create identity` still wants a subtype token (`... create identity device NAME`); check
`ziti edge create identity --help`.

## 3. Enroll the travel router (on the Slate)

```
ziti-edge-tunnel enroll --jwt /tmp/<TRAVEL_ID>.jwt --identity /etc/ziti/identities/<TRAVEL_ID>.json
chmod 600 /etc/ziti/identities/<TRAVEL_ID>.json
```

Do NOT start ZET yet if a wildcard intercept is authorized and the firewall/underlay steps are not staged -- see the
runbook 4.2b/4.2c/4.3 and the black-hole gotcha. Keep boot-autostart off (`/etc/init.d/ziti-edge-tunnel disable`)
until the firewall is staged.

## 4. Stand up the exit (pick one)

- ZET CLI, host-only (recommended, e.g. on a VPS or sg3 Windows via nssm):
  ```
  ziti-edge-tunnel enroll -j <EXIT_ID>.jwt -i <EXIT_ID>.json
  ziti-edge-tunnel run-host -i <EXIT_ID>.json     # no tun, no DNS; egresses from this box; wrap as a service
  ```
- ziti-router in host mode: a `listeners: - binding: tunnel / options: { mode: host }` stanza (equivalent to run-host).
- Reuse an existing edge router as the exit (fastest, egresses from the ER's box): add it to the Bind policy by name
  (no new identity):
  ```
  ziti edge update service-policy internet-bind --identity-roles '<EXIT_ROLE>,@<ER_NAME>'
  ```

Attribute model: anything tagged `<EXIT_ROLE>` that comes online hosts the service and load-balances (cost 0). To
force a single exit, keep only that one bound; drop the ER with `--identity-roles '<EXIT_ROLE>'` once the intended
exit is up.

## 5. Verify + monitor

```
# do the identity/service/router line up?
ziti edge policy-advisor services -q
ziti edge policy-advisor identities <TRAVEL_ID> -q     # expect Dial:Y to <SERVICE>
ziti edge policy-advisor identities <EXIT_ID> -q       # expect Bind:Y to <SERVICE>
# who is actually hosting the service right now?
ziti edge list terminators 'service.name="<SERVICE>"'
```

Terminators: a `tunnel` binding is a router's embedded tunneler hosting; an `edge` binding is an SDK client
(`run-host`) hosting. All terminators show ROUTER = the edge router they connect THROUGH (not the exit host), and the
IDENTITY column is often blank -- use the egress IP (below) as ground truth. `COST`/`DYNAMIC COST`/`PRECEDENCE`
decide selection when several are bound (lower cost wins; edge cost 0 beats a tunnel terminator at cost 4).

Prove the data plane with fabric events (authoritative -- better than curl):

```
ziti fabric stream events
```

- `circuit` namespace, `event_type: created` -- tags carry `clientId` (the dialer = `<TRAVEL_ID>`), `hostId` (the
  exit = `<EXIT_ID>`), `serviceId` (= `<SERVICE>`); `path.nodes` lists the edge router(s).
- `connect` namespace -- `src_id` = the exit identity, `src_addr` = the exit's egress source address (this is the
  home/exit public IP). Every `circuit created` is a client flow terminating at your exit and egressing there.

Client-side proof (from a non-Ziti device on the travel wifi):

```
curl -s https://ifconfig.me        # returns <EXIT_PUBLIC_IP>, not the local uplink's IP
curl -s eth0.me                    # same, also exercises DNS-through-the-tunnel
```

Do NOT test with `ping`/`traceroute`: OpenZiti carries TCP/UDP only, not ICMP. A useful signature: from behind the
router `tracert` to any host collapses to two hops (gateway -> destination) because the overlay underlay is opaque and
ICMP is not tunneled -- proof the traffic is on the overlay, not the local uplink.

## 6. Full vs split (two-service model)

- Full tunnel: `<TRAVEL_ID>` dials the wildcard `<SERVICE>` (0.0.0.0/1 + 128.0.0.0/1) -> everything egresses at the
  exit. Pair with lan->ziti forwarding + fail-closed (runbook 4.3/4.5).
- Split tunnel: a SECOND identity dials only a NARROW service whose `intercept.v1` addresses are `<HOME_SUBNET>` (and
  any specific hosts/apps you want), hosted by the same exit. Everything else stays direct via the local uplink.
  ```
  ziti edge create config home-split-intercept intercept.v1 '{"protocols":["tcp","udp"],"addresses":["<HOME_SUBNET>"],"portRanges":[{"low":1,"high":65535}]}'
  ziti edge create config home-split-host      host.v1      ((Get-Content -Raw .\internet-host.json).Trim())
  ziti edge create service home-split-svc -c home-split-intercept,home-split-host -a split-services
  ziti edge create service-policy split-dial Dial --service-roles '#split-services' --identity-roles '#travel-split' --semantic AnyOf
  ziti edge create service-policy split-bind Bind --service-roles '#split-services' --identity-roles '<EXIT_ROLE>'   --semantic AnyOf
  ziti edge create identity travel-split -a travel-split -o travel-split.jwt
  ```
  The LuCI Tunnel Mode toggle switches which identity is active (enable-by-rename of the `.json`) + flips the firewall.

## 7. Mint another traveler (no policy edits ever)

```
ziti edge create identity phone-02 -a travel-clients -o phone-02.jwt
```

Enroll it in any ZET (phone, laptop, another travel router). The `#travel-clients` Dial policy already authorizes it.

## 8. On-device firewall / DNS / recovery (Slate)

These are OpenWRT/UCI, not `ziti` -- full detail in runbook sections 4.3-4.7. Commands that cause a brief client
blip are marked DISRUPTIVE.

- ziti firewall zone + lan->ziti forwarding (DISRUPTIVE on `fw4 reload`): runbook 4.3.
- Fail-closed: delete lan->wan forwarding + the WAN-scoped DNS-leak reject (DISRUPTIVE): runbook 4.5.
- Controller/edge-router pin in `/etc/hosts` so ZET bootstraps before the tunnel exists: runbook 4.2c.
- Recovery from a black-hole (LAN SSH survives; it is not forwarded):
  ```
  /etc/init.d/ziti-edge-tunnel stop         # routes vanish, clients back to direct
  ```
  or reboot (boot-autostart disabled = clean). A workstation that roamed off the Slate LAN loses the route to the
  Slate; rejoin the Slate's own wifi/LAN to SSH it.
