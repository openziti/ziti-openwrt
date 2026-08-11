#!/usr/bin/env bash
#
# Track upstream OpenZiti releases against the versions pinned in this repo.
#
# ziti-edge-tunnel (openziti/ziti-tunnel-sdk-c) is AUTO-BUMPED: if a newer
# release exists, PKG_VERSION + PKG_HASH are rewritten and PKG_RELEASE reset to
# 1 in package/ziti-edge-tunnel/Makefile. The CI workflow (.github/workflows/
# check-upstream-versions.yml) then opens a PR with the diff, which -- once
# merged -- triggers publish-feed.yml to rebuild and republish the signed feed.
#
# ziti-router (openziti/ziti), llhttp (nodejs/llhttp) and stc (stclib/STC) are
# DETECT-ONLY: they touch multiple files or rarely change, so this script just
# reports when a newer release is out for a human to bump.
#
# Per repo convention all logic lives here; the workflow only checks out and
# runs this. Locally runnable: needs curl, jq, sha256sum, sed, sort -V.
# No auth needed for public release metadata (unauthenticated rate limits
# apply; CI passes GH_TOKEN via curl header when available).
set -euo pipefail
cd "$(dirname "$0")/.."

AUTH=()
[ -n "${GH_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer ${GH_TOKEN}")

# latest_release <owner/repo> -> tag with leading v / release/v stripped
latest_release() {
	curl -fsSL "${AUTH[@]}" -H 'Accept: application/vnd.github+json' \
		"https://api.github.com/repos/$1/releases/latest" \
		| jq -r '.tag_name' | sed -e 's#^release/v##' -e 's/^v//'
}

# is_newer NEW CUR -> success if NEW is a strictly higher version than CUR
is_newer() {
	[ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n1)" = "$1" ]
}

echo "## Upstream version check"
echo

# --- ziti-edge-tunnel : AUTO-BUMP ---
mk=package/ziti-edge-tunnel/Makefile
cur=$(sed -n 's/^PKG_VERSION:=//p' "$mk")
new=$(latest_release openziti/ziti-tunnel-sdk-c 2>/dev/null || echo "$cur")
if [ -n "$new" ] && is_newer "$new" "$cur"; then
	url="https://codeload.github.com/openziti/ziti-tunnel-sdk-c/tar.gz/refs/tags/v${new}"
	sha=$(curl -fsSL "$url" | sha256sum | awk '{print $1}')
	sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=${new}/"  "$mk"
	sed -i "s/^PKG_HASH:=.*/PKG_HASH:=${sha}/"        "$mk"
	sed -i "s/^PKG_RELEASE:=.*/PKG_RELEASE:=1/"       "$mk"
	echo "- **ziti-edge-tunnel: ${cur} -> ${new}** (Makefile bumped; PKG_HASH=${sha}; PKG_RELEASE reset to 1)"
else
	echo "- ziti-edge-tunnel: up to date (${cur})"
fi

# --- ziti router : DETECT ONLY (bump lives in two files) ---
rcur=$(sed -n 's/^PKG_VERSION:=//p' package/ziti-router/Makefile)
rnew=$(latest_release openziti/ziti 2>/dev/null || echo "$rcur")
if [ -n "$rnew" ] && is_newer "$rnew" "$rcur"; then
	echo "- ziti-router: newer release **${rnew}** available (pinned ${rcur}). To bump: set PKG_VERSION in"
	echo "  package/ziti-router/Makefile AND ZITI_VERSION in tools/build-ziti-router.sh (must match), then update"
	echo "  PKG_HASH from https://github.com/openziti/ziti/releases/download/v${rnew}/checksums.sha256.txt"
else
	echo "- ziti-router: up to date (${rcur})"
fi

# --- llhttp : DETECT ONLY ---
lcur=$(sed -n 's/^PKG_VERSION:=//p' package/llhttp/Makefile)
lnew=$(latest_release nodejs/llhttp 2>/dev/null || echo "$lcur")
if [ -n "$lnew" ] && is_newer "$lnew" "$lcur"; then
	echo "- llhttp: newer release **${lnew}** available (pinned ${lcur}); bump package/llhttp/Makefile PKG_VERSION + PKG_HASH"
else
	echo "- llhttp: up to date (${lcur})"
fi
