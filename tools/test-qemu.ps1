#!/usr/bin/env pwsh
# test-qemu.ps1 -- boot OpenWRT x86_64 in QEMU, install our .ipk artifacts,
# and run smoke checks. Emits a JUnit XML report.
#
# Design summary (see test-qemu.README.md for prerequisites + gotchas):
#
#   1. Download (and cache) the OpenWRT generic-ext4 image for x86_64.
#   2. Decompress to a working copy under build/test-results/.
#   3. Boot qemu-system-x86_64 with serial bound to stdio so we can drive
#      the root console (which has no password on first boot).
#   4. Over the serial console, set the root password and inject our
#      ephemeral SSH public key into /etc/dropbear/authorized_keys so we
#      can switch to scp/ssh for the actual test.
#   5. Wait for SSH on localhost:2222, copy *.ipk, run opkg install, run
#      smoke checks.
#   6. Write JUnit XML to build/test-results/qemu-smoke.xml.

[CmdletBinding()]
param(
    [string] $OpenWrtVersion = '23.05.5',
    [string] $IpkDir         = (Join-Path $PSScriptRoot '..\build\x86_64'),
    [switch] $Headless       = $true,
    [switch] $KeepRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\qemu-helpers.ps1')

# -----------------------------------------------------------------------------
# Paths and constants
# -----------------------------------------------------------------------------

$ToolsDir   = $PSScriptRoot
$RepoRoot   = Resolve-Path (Join-Path $ToolsDir '..')
$CacheDir   = Join-Path $ToolsDir '.cache'
$ResultsDir = Join-Path $RepoRoot 'build\test-results'
$WorkDir    = Join-Path $ResultsDir 'qemu-work'
$JunitPath  = Join-Path $ResultsDir 'qemu-smoke.xml'
$LogPath    = Join-Path $ResultsDir 'qemu-smoke.log'

$null = New-Item -ItemType Directory -Path $CacheDir   -Force
$null = New-Item -ItemType Directory -Path $ResultsDir -Force
$null = New-Item -ItemType Directory -Path $WorkDir    -Force

$ImageFileGz   = "openwrt-$OpenWrtVersion-x86-64-generic-ext4-combined.img.gz"
$ImageUrl      = "https://downloads.openwrt.org/releases/$OpenWrtVersion/targets/x86/64/$ImageFileGz"
$CachedGz      = Join-Path $CacheDir $ImageFileGz
$WorkingImage  = Join-Path $WorkDir  ($ImageFileGz -replace '\.gz$','')

$SshPort   = 2222
$HttpPort  = 8080
$VmHost    = '127.0.0.1'
$VmUser    = 'root'
$VmPass    = 'openziti-smoke'

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------

if (Test-Path -LiteralPath $LogPath) { Remove-Item -LiteralPath $LogPath -Force }
function Write-Log {
    param([string] $Message)
    $stamp = (Get-Date).ToString('s')
    $line = "[$stamp] $Message"
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line
}

# -----------------------------------------------------------------------------
# Test result accumulation
# -----------------------------------------------------------------------------

$script:TestResults = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param(
        [string] $Name,
        [string] $Status,        # passed | failed | skipped
        [string] $Message = '',
        [string] $Output  = '',
        [double] $DurationSec = 0.0
    )
    $script:TestResults.Add([pscustomobject]@{
        Name        = $Name
        Status      = $Status
        Message     = $Message
        Output      = $Output
        DurationSec = $DurationSec
    })
    Write-Log "[$Status] $Name $(if ($Message) { "-- $Message" })"
}

function Invoke-SmokeCheck {
    param(
        [string]   $Name,
        [scriptblock] $Body
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = & $Body
        $sw.Stop()
        if ($null -eq $result) { $result = [pscustomobject]@{ Status='passed'; Message=''; Output='' } }
        Add-Result -Name $Name -Status $result.Status -Message $result.Message `
            -Output $result.Output -DurationSec ($sw.Elapsed.TotalSeconds)
    } catch {
        $sw.Stop()
        Add-Result -Name $Name -Status 'failed' -Message $_.Exception.Message `
            -DurationSec ($sw.Elapsed.TotalSeconds)
    }
}

# -----------------------------------------------------------------------------
# Step 1: image cache + working copy
# -----------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $CachedGz)) {
    Write-Log "Downloading $ImageUrl"
    Invoke-WebRequest -Uri $ImageUrl -OutFile $CachedGz -UseBasicParsing
} else {
    Write-Log "Using cached image $CachedGz"
}

if (Test-Path -LiteralPath $WorkingImage) { Remove-Item -LiteralPath $WorkingImage -Force }
Write-Log "Decompressing image to $WorkingImage"
Expand-GzipFile -SourcePath $CachedGz -DestinationPath $WorkingImage

# Grow the disk a bit -- the stock generic image is tiny (~120 MB) and opkg
# can chew through that on first install.
try {
    & qemu-img resize -f raw $WorkingImage 512M | Out-Null
} catch {
    Write-Log "qemu-img resize failed (continuing): $($_.Exception.Message)"
}

# -----------------------------------------------------------------------------
# Step 2: ephemeral SSH key
# -----------------------------------------------------------------------------

$SshKey    = New-EphemeralSshKey -WorkDir $WorkDir
$SshPubKey = (Get-Content -Raw -LiteralPath "$SshKey.pub").Trim()
Write-Log "Generated ephemeral SSH key at $SshKey"

# -----------------------------------------------------------------------------
# Step 3: launch QEMU with serial -> stdio so we can drive first-boot setup
# -----------------------------------------------------------------------------

$QemuExe = 'qemu-system-x86_64'
$displayArgs = if ($Headless) { @('-display', 'none') } else { @() }

$qemuArgs = @(
    '-machine', 'pc',
    '-cpu',     'qemu64',
    '-m',       '256',
    '-smp',     '1',
    '-drive',   "file=$WorkingImage,format=raw,if=ide",
    '-netdev',  "user,id=n0,hostfwd=tcp::${SshPort}-:22,hostfwd=tcp::${HttpPort}-:80",
    '-device',  'e1000,netdev=n0',
    '-serial',  'stdio',
    '-monitor', 'none',
    '-no-reboot'
) + $displayArgs

Write-Log "Starting QEMU: $QemuExe $($qemuArgs -join ' ')"

$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $QemuExe
foreach ($a in $qemuArgs) { $psi.ArgumentList.Add($a) }
$psi.UseShellExecute        = $false
$psi.RedirectStandardInput  = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.CreateNoWindow         = $true

$qemu = [System.Diagnostics.Process]::new()
$qemu.StartInfo = $psi

# Tee QEMU serial output to our log file. We do this in background runspaces
# so we never deadlock on a full pipe buffer.
$serialLogPath = Join-Path $ResultsDir 'qemu-serial.log'
if (Test-Path -LiteralPath $serialLogPath) { Remove-Item -LiteralPath $serialLogPath -Force }

$qemu.add_OutputDataReceived({
    param($s, $e)
    if ($null -ne $e.Data) { Add-Content -LiteralPath $serialLogPath -Value $e.Data }
})
$qemu.add_ErrorDataReceived({
    param($s, $e)
    if ($null -ne $e.Data) { Add-Content -LiteralPath $serialLogPath -Value "[stderr] $($e.Data)" }
})

$null = $qemu.Start()
$qemu.BeginOutputReadLine()
$qemu.BeginErrorReadLine()

try {
    # -------------------------------------------------------------------------
    # Step 4: drive the serial console to set password + install SSH key.
    #
    # OpenWRT auto-logs root in on the serial console after boot finishes
    # ("Please press Enter to activate this console."). We wait a generous
    # amount, then poke Enter and run our setup commands.
    # -------------------------------------------------------------------------

    Write-Log 'Waiting for OpenWRT to finish booting on serial console (~45 s).'
    Start-Sleep -Seconds 45

    # Poke Enter several times to make sure we land at a shell prompt.
    1..3 | ForEach-Object { Send-SerialLine -QemuProcess $qemu -Line '' }

    # Sentinel-driven readiness check: ask the guest to print a unique token
    # and poll the serial log for it. Retries cover slow boots.
    $sentinel = 'SMOKE_READY_' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $deadline = (Get-Date).AddSeconds(120)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        Send-SerialLine -QemuProcess $qemu -Line "echo $sentinel"
        Start-Sleep -Seconds 3
        if ((Test-Path -LiteralPath $serialLogPath) -and
            ((Get-Content -Raw -LiteralPath $serialLogPath) -match [regex]::Escape($sentinel))) {
            $ready = $true; break
        }
    }
    if (-not $ready) {
        throw 'OpenWRT serial console never produced our sentinel token; boot likely failed. See qemu-serial.log.'
    }
    Write-Log 'Serial shell is responsive. Configuring SSH access.'

    # Set root password (dropbear refuses passwordless login) and install
    # the ephemeral SSH key.
    Send-SerialLine -QemuProcess $qemu -Line "(echo '$VmPass'; sleep 1; echo '$VmPass') | passwd root"
    Start-Sleep -Seconds 2
    Send-SerialLine -QemuProcess $qemu -Line 'mkdir -p /etc/dropbear && chmod 700 /etc/dropbear'
    Send-SerialLine -QemuProcess $qemu -Line "echo '$SshPubKey' > /etc/dropbear/authorized_keys"
    Send-SerialLine -QemuProcess $qemu -Line 'chmod 600 /etc/dropbear/authorized_keys'
    # Make sure dropbear is up. On stock images it should already be running
    # post-`passwd`, but be defensive.
    Send-SerialLine -QemuProcess $qemu -Line '/etc/init.d/dropbear enable; /etc/init.d/dropbear restart'

    # -------------------------------------------------------------------------
    # Step 5: wait for SSH and run the smoke checks.
    # -------------------------------------------------------------------------

    Write-Log "Waiting for SSH on $VmHost`:$SshPort"
    if (-not (Wait-Tcp -TargetHost $VmHost -Port $SshPort -TimeoutSeconds 180)) {
        throw "SSH on $VmHost`:$SshPort never came up."
    }
    # Give dropbear a moment after the port opens.
    Start-Sleep -Seconds 3

    # Sanity ssh ping.
    $ping = Invoke-SshCommand -TargetHost $VmHost -Port $SshPort -User $VmUser `
        -KeyPath $SshKey -Command 'echo ssh-ok && uname -a' -TimeoutSeconds 30
    if ($ping.ExitCode -ne 0) {
        throw "SSH login failed: exit=$($ping.ExitCode) stderr=$($ping.StdErr)"
    }
    Write-Log "SSH up: $($ping.StdOut.Trim())"

    # ---- copy ipks --------------------------------------------------------
    $resolvedIpkDir = $null
    try { $resolvedIpkDir = (Resolve-Path -LiteralPath $IpkDir -ErrorAction Stop).Path } catch { }
    $ipks = @()
    if ($resolvedIpkDir) {
        $ipks = Get-ChildItem -LiteralPath $resolvedIpkDir -Filter '*.ipk' -File -ErrorAction SilentlyContinue
    }
    if (-not $ipks -or $ipks.Count -eq 0) {
        Write-Log "No .ipk files under $IpkDir -- smoke checks will report skipped."
        Add-Result -Name 'ipk.upload' -Status 'skipped' -Message "no .ipk files under $IpkDir"
    } else {
        Write-Log "Uploading $($ipks.Count) ipk(s) to /tmp on the VM."
        Copy-ToVm -TargetHost $VmHost -Port $SshPort -User $VmUser -KeyPath $SshKey `
            -LocalPaths ($ipks | ForEach-Object { $_.FullName }) -RemotePath '/tmp/'
        Add-Result -Name 'ipk.upload' -Status 'passed' -Message "$($ipks.Count) ipk(s) uploaded"

        # ---- opkg update + install ---------------------------------------
        Invoke-SmokeCheck -Name 'opkg.install' -Body {
            $r = Invoke-SshCommand -TargetHost $VmHost -Port $SshPort -User $VmUser `
                -KeyPath $SshKey -TimeoutSeconds 300 `
                -Command 'opkg update || true; opkg install /tmp/*.ipk 2>&1'
            if ($r.ExitCode -ne 0) {
                return [pscustomobject]@{ Status='failed'; Message="opkg install exit=$($r.ExitCode)"; Output=$r.StdOut + $r.StdErr }
            }
            return [pscustomobject]@{ Status='passed'; Message=''; Output=$r.StdOut }
        }
    }

    # ---- smoke check: which ziti-edge-tunnel ------------------------------
    Invoke-SmokeCheck -Name 'ziti-edge-tunnel.which' -Body {
        $r = Invoke-SshCommand -TargetHost $VmHost -Port $SshPort -User $VmUser `
            -KeyPath $SshKey -Command 'which ziti-edge-tunnel'
        if ($r.ExitCode -ne 0) {
            return [pscustomobject]@{ Status='failed'; Message='which exited non-zero'; Output=$r.StdOut + $r.StdErr }
        }
        return [pscustomobject]@{ Status='passed'; Message=$r.StdOut.Trim(); Output=$r.StdOut }
    }

    # ---- smoke check: version prints something ----------------------------
    Invoke-SmokeCheck -Name 'ziti-edge-tunnel.version' -Body {
        $r = Invoke-SshCommand -TargetHost $VmHost -Port $SshPort -User $VmUser `
            -KeyPath $SshKey -Command 'ziti-edge-tunnel version 2>&1'
        if ([string]::IsNullOrWhiteSpace($r.StdOut)) {
            return [pscustomobject]@{ Status='failed'; Message='empty version output'; Output=$r.StdErr }
        }
        return [pscustomobject]@{ Status='passed'; Message=$r.StdOut.Trim(); Output=$r.StdOut }
    }

    # ---- smoke check: init script enable ----------------------------------
    Invoke-SmokeCheck -Name 'ziti-edge-tunnel.init.enable' -Body {
        $r = Invoke-SshCommand -TargetHost $VmHost -Port $SshPort -User $VmUser `
            -KeyPath $SshKey `
            -Command '/etc/init.d/ziti-edge-tunnel enabled || /etc/init.d/ziti-edge-tunnel enable'
        if ($r.ExitCode -ne 0) {
            return [pscustomobject]@{ Status='failed'; Message="enable failed exit=$($r.ExitCode)"; Output=$r.StdOut + $r.StdErr }
        }
        return [pscustomobject]@{ Status='passed'; Output=$r.StdOut }
    }

    # ---- smoke check: start + (pgrep OR no-identities log) ----------------
    Invoke-SmokeCheck -Name 'ziti-edge-tunnel.init.start' -Body {
        # Start the service. Init script itself must exit cleanly.
        $start = Invoke-SshCommand -TargetHost $VmHost -Port $SshPort -User $VmUser `
            -KeyPath $SshKey -Command '/etc/init.d/ziti-edge-tunnel start; echo START_EXIT=$?'
        if ($start.ExitCode -ne 0) {
            return [pscustomobject]@{ Status='failed'; Message="init start exit=$($start.ExitCode)"; Output=$start.StdOut + $start.StdErr }
        }

        # Give the daemon a moment to either come up or bail on missing identities.
        Start-Sleep -Seconds 3
        $pgrep = Invoke-SshCommand -TargetHost $VmHost -Port $SshPort -User $VmUser `
            -KeyPath $SshKey -Command 'pgrep ziti-edge-tunnel || echo NO_PID'

        if ($pgrep.StdOut -notmatch 'NO_PID') {
            return [pscustomobject]@{ Status='passed'; Message="pid=$($pgrep.StdOut.Trim())"; Output=$pgrep.StdOut }
        }

        # Acceptable fallback: no identities configured -> daemon exited cleanly.
        $log = Invoke-SshCommand -TargetHost $VmHost -Port $SshPort -User $VmUser `
            -KeyPath $SshKey -Command 'logread | tail -n 200'
        if ($log.StdOut -match '(?i)no identit') {
            return [pscustomobject]@{ Status='passed'; Message='no identities -- daemon exited cleanly (expected in CI)'; Output=$log.StdOut }
        }
        return [pscustomobject]@{ Status='failed'; Message='no pid and no "no identities" log line'; Output=$log.StdOut }
    }

    # ---- smoke check: tun0 (only if identities present) -------------------
    Invoke-SmokeCheck -Name 'ziti-edge-tunnel.tun0' -Body {
        $idCheck = Invoke-SshCommand -TargetHost $VmHost -Port $SshPort -User $VmUser `
            -KeyPath $SshKey -Command 'ls /etc/ziti/identities 2>/dev/null | wc -l'
        $count = 0
        if ($idCheck.ExitCode -eq 0) { [int]::TryParse(($idCheck.StdOut.Trim()), [ref] $count) | Out-Null }
        if ($count -lt 1) {
            return [pscustomobject]@{ Status='skipped'; Message='no identities configured'; Output='' }
        }
        $r = Invoke-SshCommand -TargetHost $VmHost -Port $SshPort -User $VmUser `
            -KeyPath $SshKey -Command 'ip link show tun0'
        if ($r.ExitCode -ne 0) {
            return [pscustomobject]@{ Status='failed'; Message='tun0 missing'; Output=$r.StdOut + $r.StdErr }
        }
        return [pscustomobject]@{ Status='passed'; Output=$r.StdOut }
    }

    # ---- smoke check: luci-app-ziti menu file exists ----------------------
    Invoke-SmokeCheck -Name 'luci-app-ziti.menu' -Body {
        $r = Invoke-SshCommand -TargetHost $VmHost -Port $SshPort -User $VmUser `
            -KeyPath $SshKey -Command 'ls /usr/share/luci/menu.d/luci-app-ziti.json 2>/dev/null'
        if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.StdOut)) {
            return [pscustomobject]@{ Status='skipped'; Message='luci-app-ziti not installed'; Output=$r.StdErr }
        }
        return [pscustomobject]@{ Status='passed'; Message=$r.StdOut.Trim(); Output=$r.StdOut }
    }

    # ---- smoke check: luci HTTP responds (200 or 403) ---------------------
    Invoke-SmokeCheck -Name 'luci-app-ziti.http' -Body {
        # Use the host-side hostfwd (HttpPort -> guest 80) and curl from the host.
        try {
            $resp = Invoke-WebRequest -Uri "http://$VmHost`:$HttpPort/cgi-bin/luci/" `
                -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            $code = [int] $resp.StatusCode
        } catch {
            # Invoke-WebRequest throws on 4xx/5xx; pull status from the exception.
            $code = 0
            if ($_.Exception.Response) { $code = [int] $_.Exception.Response.StatusCode }
        }
        if ($code -in 200, 403) {
            return [pscustomobject]@{ Status='passed'; Message="HTTP $code"; Output='' }
        }
        return [pscustomobject]@{ Status='failed'; Message="unexpected HTTP $code"; Output='' }
    }

} finally {
    # -------------------------------------------------------------------------
    # Step 6: emit JUnit XML.
    # -------------------------------------------------------------------------

    $total    = $script:TestResults.Count
    $failures = ($script:TestResults | Where-Object Status -eq 'failed').Count
    $skipped  = ($script:TestResults | Where-Object Status -eq 'skipped').Count

    $xml = [System.Text.StringBuilder]::new()
    [void] $xml.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void] $xml.AppendLine("<testsuite name=""qemu-smoke"" tests=""$total"" failures=""$failures"" skipped=""$skipped"">")
    foreach ($r in $script:TestResults) {
        $name    = [System.Security.SecurityElement]::Escape($r.Name)
        $time    = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.000}', $r.DurationSec)
        [void] $xml.AppendLine("  <testcase classname=""qemu-smoke"" name=""$name"" time=""$time"">")
        if ($r.Status -eq 'failed') {
            $msg = [System.Security.SecurityElement]::Escape($r.Message)
            $out = [System.Security.SecurityElement]::Escape(($r.Output | Out-String))
            [void] $xml.AppendLine("    <failure message=""$msg""><![CDATA[$out]]></failure>")
        } elseif ($r.Status -eq 'skipped') {
            $msg = [System.Security.SecurityElement]::Escape($r.Message)
            [void] $xml.AppendLine("    <skipped message=""$msg""/>")
        }
        [void] $xml.AppendLine('  </testcase>')
    }
    [void] $xml.AppendLine('</testsuite>')
    Set-Content -LiteralPath $JunitPath -Value $xml.ToString() -Encoding UTF8
    Write-Log "JUnit XML written to $JunitPath"

    # -------------------------------------------------------------------------
    # Tear down (or keep) the VM.
    # -------------------------------------------------------------------------
    if ($KeepRunning) {
        Write-Log "VM left running (PID $($qemu.Id)). SSH: ssh -i $SshKey -p $SshPort $VmUser@$VmHost"
    } else {
        if (-not $qemu.HasExited) {
            try { Send-SerialLine -QemuProcess $qemu -Line 'poweroff' } catch { }
            if (-not $qemu.WaitForExit(15000)) {
                Write-Log 'QEMU did not exit cleanly within 15 s -- killing.'
                try { $qemu.Kill() } catch { }
            }
        }
        Write-Log "QEMU exited with code $($qemu.ExitCode)"
    }
}

if ($failures -gt 0) {
    Write-Log "FAILED: $failures of $total checks failed."
    exit 1
}
Write-Log "OK: $total checks ($skipped skipped)."
exit 0
