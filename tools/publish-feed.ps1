<#
.SYNOPSIS
    Build an opkg feed (Packages, Packages.gz, optional Packages.sig) from
    .ipk files produced by the SDK harness.

.DESCRIPTION
    For each <target> subdirectory under -IpkRoot that contains *.ipk files,
    mirrors the .ipk files into -OutDir/<target>/ and generates an opkg
    Packages index + gzipped index. If -SigningKey is supplied, signs the
    Packages file with `usign` to produce Packages.sig.

    The actual parsing of .ipk archives (ar -> control.tar.gz -> control)
    runs inside a small alpine container built from tools/Dockerfile.feed,
    which already bundles `ar` (binutils), `tar`, `gzip`, and `usign`. This
    avoids requiring Git Bash, WSL, or a usign binary on the Windows host.

.PARAMETER IpkRoot
    Root directory whose immediate subdirs are per-target build outputs
    containing .ipk files. Default: ..\build relative to this script.

.PARAMETER OutDir
    Output directory for the feed. Default: ..\build\feed relative to this
    script.

.PARAMETER SigningKey
    Optional path to a usign secret key (e.g. as produced by
    `usign -G -p pub.key -s sec.key`). If omitted, the feed is unsigned and
    a warning is emitted.

.PARAMETER BaseUrl
    Optional. Informational only; recorded in the top-level feed-info.json
    so consumers/tools can construct per-target opkg URLs without guessing.

.EXAMPLE
    ./tools/publish-feed.ps1
    ./tools/publish-feed.ps1 -SigningKey C:\keys\openziti-feed.sec -BaseUrl https://example.github.io/openwrt-openziti
#>

[CmdletBinding()]
param(
    [string]$IpkRoot,
    [string]$OutDir,
    [string]$SigningKey,
    [string]$BaseUrl
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir

if (-not $IpkRoot) { $IpkRoot = Join-Path $repoRoot 'build' }
if (-not $OutDir)  { $OutDir  = Join-Path $repoRoot 'build\feed' }

$IpkRoot = (Resolve-Path -LiteralPath $IpkRoot -ErrorAction SilentlyContinue)?.Path
if (-not $IpkRoot) {
    throw "IpkRoot does not exist. Build some .ipk files first (./tools/build-sdk.ps1 ...)."
}

# Ensure OutDir exists (create if needed) so we can resolve its absolute path.
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

if ($SigningKey) {
    if (-not (Test-Path -LiteralPath $SigningKey)) {
        throw "SigningKey path not found: $SigningKey"
    }
    $SigningKey = (Resolve-Path -LiteralPath $SigningKey).Path
}

Write-Host "[publish-feed] IpkRoot   : $IpkRoot"
Write-Host "[publish-feed] OutDir    : $OutDir"
Write-Host "[publish-feed] SigningKey: $(if ($SigningKey) { $SigningKey } else { '<none>' })"
Write-Host "[publish-feed] BaseUrl   : $(if ($BaseUrl)    { $BaseUrl    } else { '<none>' })"

# Verify Docker is available.
$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCmd) {
    throw "Docker not found on PATH. publish-feed.ps1 invokes a small alpine container to parse .ipk archives and run usign."
}

# Build the helper image (cheap when cached).
$imageTag = 'openwrt-openziti-feed:latest'
$dockerfile = Join-Path $scriptDir 'Dockerfile.feed'
if (-not (Test-Path -LiteralPath $dockerfile)) {
    throw "Missing $dockerfile"
}

Write-Host "[publish-feed] building helper image $imageTag ..."
& docker build -f $dockerfile -t $imageTag $scriptDir | Write-Host
if ($LASTEXITCODE -ne 0) { throw "docker build failed" }

# Compose docker run args.
$dockerArgs = @(
    'run','--rm',
    '-v', "${IpkRoot}:/in:ro",
    '-v', "${OutDir}:/out",
    '-e', 'IPK_ROOT=/in',
    '-e', 'OUT_DIR=/out',
    '-e', "BASE_URL=$BaseUrl"
)

if ($SigningKey) {
    $dockerArgs += @('-v', "${SigningKey}:/key/sec.key:ro", '-e', 'SIGN_KEY=/key/sec.key')
} else {
    $dockerArgs += @('-e', 'SIGN_KEY=')
    Write-Warning "No -SigningKey provided. The published feed will be UNSIGNED. Devices must use 'opkg --force-signature' or skip signature checks."
}

$dockerArgs += $imageTag

Write-Host "[publish-feed] running container ..."
& docker @dockerArgs
if ($LASTEXITCODE -ne 0) { throw "publish-feed container failed (exit $LASTEXITCODE)" }

$feedInfo = Join-Path $OutDir 'feed-info.json'
if (Test-Path -LiteralPath $feedInfo) {
    Write-Host "[publish-feed] feed-info.json:"
    Get-Content -LiteralPath $feedInfo | Write-Host
}

Write-Host "[publish-feed] done. Feed root: $OutDir"
