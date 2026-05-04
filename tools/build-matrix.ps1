<#
.SYNOPSIS
    Run build-sdk.ps1 across the openwrt-openziti target matrix.

.DESCRIPTION
    Invokes build-sdk.ps1 once per target. Continues on failure and writes
    a per-target pass/fail record to build/matrix-result.json.
#>
[CmdletBinding()]
param(
    [string] $Package        = "ziti-edge-tunnel",
    [string] $OpenWrtVersion = "23.05.5",
    [string[]] $Targets      = @(
        "aarch64_cortex-a53",
        "x86_64",
        "arm_cortex-a7",
        "mipsel_24kc",
        "mips_24kc"
    )
)

$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Resolve-Path (Join-Path $ScriptDir "..")
$BuildSdk  = Join-Path $ScriptDir "build-sdk.ps1"

$BuildDir = Join-Path $RepoRoot "build"
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
$ResultFile = Join-Path $BuildDir "matrix-result.json"

$results = @()
foreach ($t in $Targets) {
    Write-Host ""
    Write-Host "================ TARGET: $t ================"
    $start = Get-Date
    $status = "pass"
    $errorMsg = $null

    try {
        & $BuildSdk -Target $t -Package $Package -OpenWrtVersion $OpenWrtVersion
        if ($LASTEXITCODE -ne 0) {
            $status = "fail"
            $errorMsg = "build-sdk.ps1 exited with $LASTEXITCODE"
        }
    } catch {
        $status = "fail"
        $errorMsg = $_.Exception.Message
        Write-Warning "Target $t failed: $errorMsg"
    }

    $end = Get-Date
    $results += [pscustomobject]@{
        target          = $t
        package         = $Package
        openwrt_version = $OpenWrtVersion
        status          = $status
        error           = $errorMsg
        started         = $start.ToString("o")
        finished        = $end.ToString("o")
        duration_secs   = [int]($end - $start).TotalSeconds
    }

    # Write incrementally so partial runs are still useful.
    ($results | ConvertTo-Json -Depth 4) | Out-File -FilePath $ResultFile -Encoding utf8
}

Write-Host ""
Write-Host "==> Matrix complete. Results: $ResultFile"
$results | Format-Table target, status, duration_secs, error -AutoSize

$failed = ($results | Where-Object { $_.status -ne "pass" }).Count
if ($failed -gt 0) {
    Write-Host "==> $failed target(s) failed."
    exit 1
}
