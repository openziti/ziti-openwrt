<#
.SYNOPSIS
    Dev-only HTTP server for sanity-checking a generated opkg feed.

.DESCRIPTION
    Serves -FeedDir on http://localhost:<Port>/ using `python -m http.server`.
    THIS IS NOT FOR PRODUCTION. Real device feeds MUST be served over HTTPS
    so the opkg client can fetch Packages, Packages.gz, Packages.sig, and
    .ipk files securely. Use GitHub Pages, S3 + CloudFront, or any static
    HTTPS host (see docs/feed-hosting.md).

.PARAMETER FeedDir
    Path to the feed root (default: ..\build\feed).

.PARAMETER Port
    Listen port (default: 8181).
#>

[CmdletBinding()]
param(
    [string]$FeedDir,
    [int]$Port = 8181
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $FeedDir) { $FeedDir = Join-Path (Split-Path -Parent $scriptDir) 'build\feed' }

if (-not (Test-Path -LiteralPath $FeedDir)) {
    throw "FeedDir not found: $FeedDir (run ./tools/publish-feed.ps1 first)"
}
$FeedDir = (Resolve-Path -LiteralPath $FeedDir).Path

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $python) { throw "python not found on PATH (need 3.x for http.server)" }

Write-Warning "Dev-only server. Do NOT use this for real device feeds (no HTTPS). See docs/feed-hosting.md."
Write-Host "[feed-server] serving $FeedDir on http://localhost:$Port/ (Ctrl-C to stop)"
Push-Location $FeedDir
try {
    & $python.Path -m http.server $Port
} finally {
    Pop-Location
}
