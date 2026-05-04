# qemu-helpers.ps1 -- shared helpers for the QEMU smoke-test harness.
#
# These functions are deliberately small and side-effect free where possible
# so they can be re-used by other harness scripts (and unit-poked from a
# REPL during development). All functions write progress to the host's
# information stream via Write-Host so the parent script's transcript
# captures them.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Wait-Tcp {
    <#
        Polls a TCP host:port until it accepts a connection or the timeout
        elapses. Returns $true on success, $false on timeout.
    #>
    param(
        [Parameter(Mandatory)] [string] $TargetHost,
        [Parameter(Mandatory)] [int]    $Port,
        [int] $TimeoutSeconds = 180,
        [int] $IntervalSeconds = 2
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds(2))
            if ($ok -and $client.Connected) {
                $client.EndConnect($iar) | Out-Null
                $client.Close()
                return $true
            }
            $client.Close()
        } catch {
            # swallow; we will retry until the deadline
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
    return $false
}

function Get-SshCommonArgs {
    <#
        Returns the common ssh/scp argument array the harness uses. The key
        file path is required; StrictHostKeyChecking is disabled because the
        VM is ephemeral and lives only on localhost.
    #>
    param(
        [Parameter(Mandatory)] [string] $KeyPath
    )
    return @(
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'GlobalKnownHostsFile=NUL',
        '-o', 'PreferredAuthentications=publickey',
        '-o', 'IdentitiesOnly=yes',
        '-o', 'ConnectTimeout=10',
        '-o', 'LogLevel=ERROR',
        '-i', $KeyPath
    )
}

function Invoke-SshCommand {
    <#
        Runs a single command on the VM via ssh. Returns an object with
        ExitCode, StdOut, StdErr. Never throws on non-zero exit -- the
        caller decides how to interpret it.
    #>
    param(
        [Parameter(Mandatory)] [string] $TargetHost,
        [Parameter(Mandatory)] [int]    $Port,
        [Parameter(Mandatory)] [string] $User,
        [Parameter(Mandatory)] [string] $KeyPath,
        [Parameter(Mandatory)] [string] $Command,
        [int] $TimeoutSeconds = 60
    )

    $sshArgs = Get-SshCommonArgs -KeyPath $KeyPath
    $sshArgs += @('-p', "$Port", "$User@$TargetHost", $Command)

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath 'ssh' -ArgumentList $sshArgs `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError  $stderrFile
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch { }
            return [pscustomobject]@{
                ExitCode = -1
                StdOut   = (Get-Content -Raw -LiteralPath $stdoutFile -ErrorAction SilentlyContinue)
                StdErr   = "TIMEOUT after $TimeoutSeconds s"
            }
        }
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            StdOut   = (Get-Content -Raw -LiteralPath $stdoutFile -ErrorAction SilentlyContinue)
            StdErr   = (Get-Content -Raw -LiteralPath $stderrFile -ErrorAction SilentlyContinue)
        }
    } finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
    }
}

function Copy-ToVm {
    <#
        Copies one or more local files to the VM via scp. Throws on failure.
    #>
    param(
        [Parameter(Mandatory)] [string]   $TargetHost,
        [Parameter(Mandatory)] [int]      $Port,
        [Parameter(Mandatory)] [string]   $User,
        [Parameter(Mandatory)] [string]   $KeyPath,
        [Parameter(Mandatory)] [string[]] $LocalPaths,
        [Parameter(Mandatory)] [string]   $RemotePath
    )

    $scpArgs = Get-SshCommonArgs -KeyPath $KeyPath
    $scpArgs += @('-P', "$Port")
    $scpArgs += $LocalPaths
    $scpArgs += "$User@${TargetHost}:$RemotePath"

    $proc = Start-Process -FilePath 'scp' -ArgumentList $scpArgs `
        -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        throw "scp failed with exit code $($proc.ExitCode) copying [$($LocalPaths -join ', ')] to $User@${TargetHost}:$RemotePath"
    }
}

function New-EphemeralSshKey {
    <#
        Generates an ed25519 keypair under a working directory and returns
        the path to the private key. The matching public key is the same
        path with a `.pub` suffix (ssh-keygen's default).
    #>
    param(
        [Parameter(Mandatory)] [string] $WorkDir
    )
    $keyPath = Join-Path $WorkDir 'id_ed25519'
    if (Test-Path -LiteralPath $keyPath) {
        Remove-Item -LiteralPath $keyPath, "$keyPath.pub" -ErrorAction SilentlyContinue
    }
    & ssh-keygen -t ed25519 -N '""' -f $keyPath -q | Out-Null
    if (-not (Test-Path -LiteralPath $keyPath)) {
        throw "ssh-keygen failed to create $keyPath"
    }
    return $keyPath
}

function Expand-GzipFile {
    <#
        Decompresses a single .gz file to the given destination path using
        only .NET (no external gzip dependency).
    #>
    param(
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [string] $DestinationPath
    )

    $inStream  = [System.IO.File]::OpenRead($SourcePath)
    try {
        $gz = [System.IO.Compression.GZipStream]::new(
            $inStream, [System.IO.Compression.CompressionMode]::Decompress)
        try {
            $outStream = [System.IO.File]::Create($DestinationPath)
            try {
                $gz.CopyTo($outStream)
            } finally {
                $outStream.Dispose()
            }
        } finally {
            $gz.Dispose()
        }
    } finally {
        $inStream.Dispose()
    }
}

function Send-SerialLine {
    <#
        Writes a line to a QEMU serial-over-stdio process's StandardInput.
        OpenWRT's console accepts \n. We add a tiny inter-line delay so the
        guest's getty doesn't drop characters during early boot.
    #>
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process] $QemuProcess,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Line,
        [int] $PostDelayMs = 250
    )
    $QemuProcess.StandardInput.WriteLine($Line)
    $QemuProcess.StandardInput.Flush()
    Start-Sleep -Milliseconds $PostDelayMs
}
