<#
.SYNOPSIS
    Build an openwrt-openziti package using the OpenWRT SDK in Docker.

.DESCRIPTION
    Builds (or reuses) the SDK Docker image, mounts the repo's package/ tree
    as a local feed, runs feeds update/install + make package/<Package>/compile,
    then copies resulting .ipk files to build/<target>/.

    All build logic lives here; CI workflows should only check out the repo
    and invoke this script.

.PARAMETER Target
    OpenWRT target identifier (e.g. aarch64_cortex-a53). Used both for the
    output directory name and to look up the SDK URL.

.PARAMETER Package
    The package directory under package/ to compile. Defaults to
    ziti-edge-tunnel; pass _stub to validate the harness end-to-end.

.PARAMETER OpenWrtVersion
    OpenWRT release version (default 23.05.5).

.PARAMETER FeedPath
    Host path to the local feed (default: <repo>/package).

.PARAMETER SdkUrl
    Override the SDK tarball URL. If unset, derived from Target/OpenWrtVersion
    via the table in Get-SdkUrl below.

.PARAMETER ImageTag
    Docker image tag to build/use. Defaults to openwrt-openziti-sdk:<target>-<version>.

.PARAMETER SkipBuild
    If set, do not (re)build the Docker image; assume it already exists.

.PARAMETER Snapshot
    If set, force the SDK URL lookup to use the snapshots tree rather than the
    pinned OpenWrtVersion release. Snapshot-only targets (e.g.
    aarch64_cortex-a53_ipq53xx for the GL-BE3600) imply this automatically.
#>
[CmdletBinding()]
param(
    [string] $Target         = "aarch64_cortex-a53",
    [string] $Package        = "ziti-edge-tunnel",
    [string] $OpenWrtVersion = "23.05.5",
    [string] $FeedPath       = "",
    [string] $SdkUrl         = "",
    [string] $ImageTag       = "",
    [switch] $SkipBuild,
    [switch] $Snapshot
)

$ErrorActionPreference = "Stop"

# Resolve repo root (parent of tools/).
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Resolve-Path (Join-Path $ScriptDir "..")

if ([string]::IsNullOrEmpty($FeedPath)) {
    $FeedPath = Join-Path $RepoRoot "package"
}
if (-not (Test-Path $FeedPath)) {
    throw "FeedPath '$FeedPath' does not exist."
}

if ([string]::IsNullOrEmpty($ImageTag)) {
    $ImageTag = "openwrt-openziti-sdk:$Target-$OpenWrtVersion"
}

# Targets that only exist in the snapshots tree (no 23.05.x stable release).
# These force snapshot URL derivation regardless of the -Snapshot switch.
$SnapshotOnlyTargets = @(
    "aarch64_cortex-a53_ipq53xx"
)

function Get-SdkUrl {
    param([string] $T, [string] $V, [bool] $UseSnapshot)

    # Map target -> (subpath, filename suffix). Filename uses a hyphenated
    # subpath (e.g. mvebu-cortexa53). gcc/host are stable per 23.05.x.
    $gcc  = "gcc-12.3.0_musl"
    $host_ = "Linux-x86_64"

    $map = @{
        "aarch64_cortex-a53" = "mvebu/cortexa53"
        "aarch64_cortex-a72" = "mvebu/cortexa72"
        "x86_64"             = "x86/64"
        "arm_cortex-a7"      = "mvebu/cortexa9"   # closest a7-class; override via -SdkUrl for ipq40xx
        "arm_cortex-a7_neon-vfpv4" = "ipq40xx/generic"
        "mipsel_24kc"        = "ramips/mt7621"
        "mips_24kc"          = "ath79/generic"
        # SNAPSHOT-only: GL-iNet GL-BE3600 (Qualcomm IPQ5332). The qualcommax
        # ipq53xx subtarget is not in the 23.05.x stable tree; the snapshots
        # tarball name rolls with the toolchain (gcc version). If the URL
        # 404s, browse https://downloads.openwrt.org/snapshots/targets/qualcommax/ipq53xx/
        # for the current openwrt-sdk-*.tar.zst filename and pass it via
        # -SdkUrl, or update the snapshot filename below.
        "aarch64_cortex-a53_ipq53xx" = "qualcommax/ipq53xx"
    }

    if (-not $map.ContainsKey($T)) {
        throw "Unknown target '$T'; pass -SdkUrl explicitly."
    }
    $sub      = $map[$T]
    $subFlat  = $sub -replace "/", "-"

    if ($UseSnapshot) {
        # Snapshots use .tar.zst and a rolling toolchain version. We default to
        # a recent gcc; update if downloads.openwrt.org rolls forward and the
        # URL 404s. Pass -SdkUrl to override without editing this script.
        $snapGcc = "gcc-13.3.0_musl"
        $fname   = "openwrt-sdk-${subFlat}_${snapGcc}.${host_}.tar.zst"
        return "https://downloads.openwrt.org/snapshots/targets/$sub/$fname"
    }

    $fname    = "openwrt-sdk-$V-${subFlat}_${gcc}.${host_}.tar.xz"
    return "https://downloads.openwrt.org/releases/$V/targets/$sub/$fname"
}

if ([string]::IsNullOrEmpty($SdkUrl)) {
    $useSnap = [bool]$Snapshot -or ($SnapshotOnlyTargets -contains $Target)
    $SdkUrl = Get-SdkUrl -T $Target -V $OpenWrtVersion -UseSnapshot $useSnap
}

Write-Host "==> Target:          $Target"
Write-Host "==> Package:         $Package"
Write-Host "==> OpenWRT version: $OpenWrtVersion"
Write-Host "==> SDK URL:         $SdkUrl"
Write-Host "==> Image tag:       $ImageTag"
Write-Host "==> Feed path:       $FeedPath"

# Verify docker is on PATH; do not actually run if missing.
$docker = Get-Command docker -ErrorAction SilentlyContinue
if ($null -eq $docker) {
    throw "docker CLI not found on PATH. Install Docker Desktop or invoke this script on a host with docker."
}

# Build image if needed.
if (-not $SkipBuild) {
    Write-Host "==> Building image $ImageTag"
    $buildArgs = @(
        "build",
        "--build-arg", "OPENWRT_VERSION=$OpenWrtVersion",
        "--build-arg", "OPENWRT_TARGET=$Target",
        "--build-arg", "OPENWRT_SDK_URL=$SdkUrl",
        "-t", $ImageTag,
        "-f", (Join-Path $ScriptDir "Dockerfile"),
        $ScriptDir
    )
    & docker @buildArgs
    if ($LASTEXITCODE -ne 0) { throw "docker build failed (exit $LASTEXITCODE)" }
}

# Output dir on host.
$OutDir = Join-Path $RepoRoot "build\$Target"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Inline build script we run inside the container.
$inner = @'
set -euo pipefail
cd /home/builder/sdk

# Wire up local feed: src-link points at the bind-mounted /feed.
{
  echo "src-link local /feed"
  cat feeds.conf.default
} > feeds.conf

# Retry feeds update -- git.openwrt.org is famously flaky on TLS,
# and a partial clone leaves us with missing feed dirs that break
# downstream `make defconfig`. Up to 4 attempts with growing backoff.
attempt=0
until ./scripts/feeds update -a; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 4 ]; then
    echo "feeds update failed after $attempt attempts" >&2
    exit 1
  fi
  echo "feeds update attempt $attempt failed; retrying after $((attempt * 5))s" >&2
  # Wipe any half-cloned feed dirs so the next attempt starts fresh.
  rm -rf feeds
  sleep $((attempt * 5))
done
./scripts/feeds install -a

make defconfig
make package/__PACKAGE__/compile V=s -j"$(nproc)"

# Collect ipks. SDK puts them under bin/packages/<arch>/ and bin/targets/...
mkdir -p /out
find bin/ -name "*.ipk" -print -exec cp {} /out/ \;
'@

$inner = $inner -replace "__PACKAGE__", $Package

# Write to a temp file we mount in.
$tmpScript = Join-Path $env:TEMP "openwrt-openziti-build-$([Guid]::NewGuid().ToString('N')).sh"
# Force LF line endings.
[System.IO.File]::WriteAllText($tmpScript, ($inner -replace "`r`n", "`n"))

try {
    Write-Host "==> Running build in container"
    $runArgs = @(
        "run", "--rm",
        "-v", "${FeedPath}:/feed:ro",
        "-v", "${OutDir}:/out",
        "-v", "${tmpScript}:/tmp/build-inner.sh:ro",
        $ImageTag,
        "bash", "/tmp/build-inner.sh"
    )
    & docker @runArgs
    if ($LASTEXITCODE -ne 0) { throw "docker run failed (exit $LASTEXITCODE)" }
} finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $tmpScript
}

$ipks = Get-ChildItem -Path $OutDir -Filter "*.ipk" -ErrorAction SilentlyContinue
Write-Host "==> Produced $($ipks.Count) .ipk file(s) in $OutDir"
foreach ($f in $ipks) { Write-Host "    $($f.Name)" }

if ($ipks.Count -eq 0) {
    throw "No .ipk artifacts produced for target=$Target package=$Package"
}
