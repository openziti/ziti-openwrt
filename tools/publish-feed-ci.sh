#!/usr/bin/env bash
# publish-feed-ci.sh -- CI-friendly wrapper that stages downloaded build
# artifacts into build/feed-input/ and produces a signed feed under
# build/feed/ ready to be deployed to gh-pages by an outer step.
#
# This script accepts the GitHub-specific signing-key value via env var so
# the same script runs locally. It does NOT push to git; the caller (the
# workflow) handles that with a stock action.
#
# Inputs (env vars):
#   USIGN_SECRET_KEY     -- multi-line contents of the usign secret key.
#                           If empty, the feed is produced unsigned (and a
#                           warning is logged). Required for production runs.
#   BASE_URL             -- public URL the feed will be served from (recorded
#                           in feed-info.json). Optional but recommended.
#   REPACK_TO_ARCH       -- pass-through to publish-feed.sh. Default repacks
#                           aarch64_cortex-a53 -> aarch64_cortex-a53_neon-vfpv4
#                           so QSDK / GL.iNet devices can install without a
#                           local repack step.
#   ARTIFACT_ROOT        -- directory containing per-target subdirs of .ipk
#                           files plus a luci/ subdir for the _all luci ipk.
#                           Defaults to build/artifacts.
#
# Layout expected under ARTIFACT_ROOT (matches what the workflow downloads):
#   <ARTIFACT_ROOT>/aarch64_cortex-a53/*.ipk
#   <ARTIFACT_ROOT>/x86_64/*.ipk
#   <ARTIFACT_ROOT>/luci/*.ipk
#
# Outputs:
#   build/feed-input/<target>/*.ipk         (staged copies)
#   build/feed/<target>/{Packages,Packages.gz,Packages.sig,*.ipk}
#   build/feed/feed-info.json
#   build/feed/pub.key                      (if PUB_KEY_FILE supplied)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ARTIFACT_ROOT="${ARTIFACT_ROOT:-$REPO_ROOT/build/artifacts}"
FEED_INPUT="$REPO_ROOT/build/feed-input"
FEED_OUT="$REPO_ROOT/build/feed"
KEYS_DIR="$REPO_ROOT/build/keys"
SECRET_KEY_FILE="$KEYS_DIR/sec.key"
PUB_KEY_FILE="${PUB_KEY_FILE:-$REPO_ROOT/docs/pub.key}"
BASE_URL="${BASE_URL:-}"
# Default repack pair: vanilla aarch64_cortex-a53 -> QSDK arch tag. Users
# can override or disable by passing REPACK_TO_ARCH= (empty) explicitly.
REPACK_TO_ARCH="${REPACK_TO_ARCH-aarch64_cortex-a53:aarch64_cortex-a53_neon-vfpv4}"

echo "==> ARTIFACT_ROOT: $ARTIFACT_ROOT"
echo "==> FEED_INPUT:    $FEED_INPUT"
echo "==> FEED_OUT:      $FEED_OUT"
echo "==> BASE_URL:      ${BASE_URL:-<unset>}"
echo "==> REPACK_TO_ARCH: ${REPACK_TO_ARCH:-<none>}"

# Stage artifacts into build/feed-input/<target>/.
rm -rf "$FEED_INPUT"
mkdir -p "$FEED_INPUT"

stage_target() {
    local target="$1"
    local src="$ARTIFACT_ROOT/$target"
    if [ ! -d "$src" ]; then
        echo "WARN: no artifact dir $src; skipping $target" >&2
        return 0
    fi
    mkdir -p "$FEED_INPUT/$target"
    # Only the openziti packages -- the SDK build tree dumps ~200 unrelated
    # ipks (linux-firmware, kmods, ...) we do not want to publish.
    for pat in 'ziti-edge-tunnel_*.ipk' 'llhttp9_*.ipk' 'ziti-router_*.ipk'; do
        for f in "$src"/$pat; do
            [ -f "$f" ] || continue
            cp -f "$f" "$FEED_INPUT/$target/"
        done
    done
}

# Detect targets present under ARTIFACT_ROOT (everything except luci/).
shopt -s nullglob
for tdir in "$ARTIFACT_ROOT"/*/; do
    name=$(basename "$tdir")
    [ "$name" = "luci" ] && continue
    stage_target "$name"
done

# luci-app-ziti is Architecture: all -- copy into every per-target dir.
if [ -d "$ARTIFACT_ROOT/luci" ]; then
    for tdir in "$FEED_INPUT"/*/; do
        for f in "$ARTIFACT_ROOT/luci"/luci-app-ziti_*.ipk; do
            [ -f "$f" ] || continue
            cp -f "$f" "$tdir"
        done
    done
fi

echo "==> Staged feed-input contents:"
find "$FEED_INPUT" -name '*.ipk' -printf '  %p\n' | sort

# Materialize the signing key from the env var (if provided). The key file
# never lands in an artifact; it lives only in this job's workspace and is
# wiped on shutdown.
sign_arg=()
if [ -n "${USIGN_SECRET_KEY:-}" ]; then
    mkdir -p "$KEYS_DIR"
    umask 077
    printf '%s\n' "$USIGN_SECRET_KEY" > "$SECRET_KEY_FILE"
    sign_arg=(-v "$SECRET_KEY_FILE:/keys/sec.key:ro" -e "SIGN_KEY=/keys/sec.key")
    echo "==> Signing key materialized at $SECRET_KEY_FILE (mode 0600)"
else
    echo "WARN: USIGN_SECRET_KEY not set; feed will be UNSIGNED" >&2
fi

# Build the publish-feed image (cheap if cached).
docker build -t openwrt-openziti-feed -f "$SCRIPT_DIR/Dockerfile.feed" "$SCRIPT_DIR"

mkdir -p "$FEED_OUT"

# Run the feed builder. publish-feed.sh handles repacking when REPACK_TO_ARCH
# is set. It also writes feed-info.json at the root.
docker run --rm \
    -v "$FEED_INPUT:/ipks:ro" \
    -v "$FEED_OUT:/out" \
    "${sign_arg[@]}" \
    -e IPK_ROOT=/ipks \
    -e OUT_DIR=/out \
    -e BASE_URL="$BASE_URL" \
    -e REPACK_TO_ARCH="$REPACK_TO_ARCH" \
    openwrt-openziti-feed

# Always wipe the secret key from the workspace so a misconfigured artifact
# upload step cannot leak it.
if [ -f "$SECRET_KEY_FILE" ]; then
    shred -u "$SECRET_KEY_FILE" 2>/dev/null || rm -f "$SECRET_KEY_FILE"
fi

# Copy the public key to the feed root so end users can curl it directly.
if [ -f "$PUB_KEY_FILE" ]; then
    cp -f "$PUB_KEY_FILE" "$FEED_OUT/pub.key"
    echo "==> Published pub.key at feed root"
else
    echo "WARN: $PUB_KEY_FILE not found; feed root will not contain pub.key" >&2
fi

echo "==> Feed produced at $FEED_OUT"
ls -la "$FEED_OUT"
