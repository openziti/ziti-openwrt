# test-qemu.ps1 -- QEMU smoke-test harness for openwrt-openziti

This harness boots OpenWRT x86_64 in QEMU, installs the `.ipk` files produced by `tools/build-sdk.ps1`,
and runs a small set of smoke checks against `ziti-edge-tunnel` and `luci-app-ziti`. Results are
written as JUnit XML so CI can render them.

## Prerequisites

The host must be a Windows machine with PowerShell 5.1 or PowerShell 7+. The following must be
on `$env:PATH`:

- `qemu-system-x86_64` and `qemu-img`. Install via either:
  - Chocolatey: `choco install qemu` -- usually drops binaries into
    `C:\Program Files\qemu\` and adds them to PATH.
  - Scoop: `scoop install qemu` -- typically lands under
    `%USERPROFILE%\scoop\apps\qemu\current\`.
  - Official installer from <https://www.qemu.org/download/#windows>.
- OpenSSH client (`ssh`, `scp`, `ssh-keygen`). Windows 10/11 ship this as an optional feature:
  `Settings -> Apps -> Optional features -> "OpenSSH Client"`.

Verify with:

```powershell
qemu-system-x86_64 --version
qemu-img --version
ssh -V
```

## How to invoke

From the repo root:

```powershell
# Default: 23.05.5, ipks under build\x86_64, headless, VM torn down after tests.
.\tools\test-qemu.ps1

# Specify a different OpenWRT version and ipk directory:
.\tools\test-qemu.ps1 -OpenWrtVersion 23.05.5 `
    -IpkDir .\build\x86_64

# Leave the VM running for manual poking; the script will print the ssh command.
.\tools\test-qemu.ps1 -KeepRunning

# Show QEMU's window (useful for debugging boot issues):
.\tools\test-qemu.ps1 -Headless:$false
```

Outputs:

- `build\test-results\qemu-smoke.xml` -- JUnit report.
- `build\test-results\qemu-smoke.log` -- harness log.
- `build\test-results\qemu-serial.log` -- raw serial console output from the guest.
- `tools\.cache\openwrt-<ver>-x86-64-generic-ext4-combined.img.gz` -- cached image (gitignored).

## How first-boot login is handled

OpenWRT ships with an empty root password and dropbear refuses passwordless logins, so we cannot
just SSH in immediately. The harness takes the simplest reliable path on Windows (no `guestfs`,
no `expect`):

1. QEMU is started with `-serial stdio`, giving the harness direct access to the guest's
   auto-logged-in root console.
2. We poll the serial output for a sentinel echo to detect the shell-ready point.
3. Over that console we run `passwd root`, drop our ephemeral SSH public key into
   `/etc/dropbear/authorized_keys`, and restart dropbear.
4. From that point on, all real test commands go through `ssh`/`scp` against `localhost:2222`.

The SSH keypair is generated fresh per run under `build\test-results\qemu-work\`.

## Gotchas

- **Windows Defender + QEMU**: real-time AV scanning of the disk image can slow the run by an
  order of magnitude. Add `tools\.cache` and `build\test-results\qemu-work` to Defender's
  exclusion list if smoke runs feel pathologically slow.
- **No KVM on Windows**: QEMU on Windows runs in TCG mode (software emulation). A full smoke
  run typically takes 2-4 minutes. Linux CI runners with `/dev/kvm` available should be much
  faster -- the script does not pass `-enable-kvm` because we target Windows hosts; add it
  yourself in a Linux variant if needed.
- **Port conflicts**: the script binds host ports `2222` (SSH) and `8080` (LuCI HTTP). If
  another process is using them, QEMU will fail at startup. Stop the offending process or
  edit the script.
- **First run is slow**: the OpenWRT image (~4 MB compressed) is downloaded once and cached.
  Subsequent runs reuse the cache.
- **`qemu-img resize`**: the harness grows the disk to 512 MB so opkg has room. If your QEMU
  build lacks `qemu-img` on PATH, the script logs a warning and continues -- you may then hit
  ENOSPC during `opkg install`.

## What the smoke checks prove (and don't)

The checks exercise packaging and start-up plumbing only. They do **not** prove a working data
plane: there is no Ziti controller in the loop, no enrolled identity, and no overlay traffic.
See the design notes printed at the top of `test-qemu.ps1` for details.
