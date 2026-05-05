#!/usr/bin/env bash
# Bash twin of build-sdk.ps1. Same logic, same image, same mounts.
# Usage: tools/build-sdk.sh [-t target] [-p package] [-v openwrt_version] [-u sdk_url]

set -euo pipefail

TARGET="aarch64_cortex-a53"
PACKAGE="ziti-edge-tunnel"
OPENWRT_VERSION="23.05.5"
SDK_URL=""

while getopts "t:p:v:u:" opt; do
  case "$opt" in
    t) TARGET="$OPTARG" ;;
    p) PACKAGE="$OPTARG" ;;
    v) OPENWRT_VERSION="$OPTARG" ;;
    u) SDK_URL="$OPTARG" ;;
    *) echo "usage: $0 [-t target] [-p package] [-v openwrt_version] [-u sdk_url]" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FEED_PATH="$REPO_ROOT/package"
OUT_DIR="$REPO_ROOT/build/$TARGET"
mkdir -p "$OUT_DIR"

# Optional persistent feeds cache. CI sets FEEDS_CACHE_DIR to a path that
# actions/cache@v4 saves between runs, so feeds update only does a git pull
# instead of a full clone (~3-5 min savings per leg).
FEEDS_CACHE_DIR="${FEEDS_CACHE_DIR:-}"
FEEDS_MOUNT_ARG=()
if [ -n "$FEEDS_CACHE_DIR" ]; then
  mkdir -p "$FEEDS_CACHE_DIR"
  chmod 0777 "$FEEDS_CACHE_DIR"
  FEEDS_MOUNT_ARG=(-v "$FEEDS_CACHE_DIR:/home/builder/sdk/feeds")
fi
# The SDK container runs as uid 1000 (builder); on Linux Docker the host
# uid is preserved, so a dir owned by host uid 1001 (typical CI runner) is
# unwritable to container uid 1000. Open it for the container to write
# .ipks back into. Local Docker Desktop on Windows hides this with uid
# translation; Linux runners do not.
chmod 0777 "$OUT_DIR"

# Default SDK URL mapping (mirrors build-sdk.ps1's table; trim as needed).
if [ -z "$SDK_URL" ]; then
  case "$TARGET" in
    aarch64_cortex-a53)
      SDK_URL="https://downloads.openwrt.org/releases/$OPENWRT_VERSION/targets/mvebu/cortexa53/openwrt-sdk-${OPENWRT_VERSION}-mvebu-cortexa53_gcc-12.3.0_musl.Linux-x86_64.tar.xz"
      ;;
    aarch64_cortex-a53_ipq53xx)
      SDK_URL="https://downloads.openwrt.org/snapshots/targets/qualcommax/ipq53xx/openwrt-sdk-qualcommax-ipq53xx_gcc-13.3.0_musl.Linux-x86_64.tar.zst"
      ;;
    x86_64)
      SDK_URL="https://downloads.openwrt.org/releases/$OPENWRT_VERSION/targets/x86/64/openwrt-sdk-${OPENWRT_VERSION}-x86-64_gcc-12.3.0_musl.Linux-x86_64.tar.xz"
      ;;
    *)
      echo "no default SDK URL for target=$TARGET; pass -u" >&2
      exit 2
      ;;
  esac
fi

IMAGE_TAG="openwrt-openziti-sdk:${TARGET}-${OPENWRT_VERSION}"

echo "==> Target:          $TARGET"
echo "==> Package:         $PACKAGE"
echo "==> OpenWRT version: $OPENWRT_VERSION"
echo "==> SDK URL:         $SDK_URL"
echo "==> Image tag:       $IMAGE_TAG"
echo "==> Feed path:       $FEED_PATH"

echo "==> Building (or reusing) image $IMAGE_TAG"
docker build \
  --build-arg "OPENWRT_VERSION=$OPENWRT_VERSION" \
  --build-arg "OPENWRT_TARGET=$TARGET" \
  --build-arg "OPENWRT_SDK_URL=$SDK_URL" \
  -t "$IMAGE_TAG" \
  -f "$SCRIPT_DIR/Dockerfile" \
  "$SCRIPT_DIR"

# Inner build script mounted into the container.
TMP_INNER="$(mktemp)"
trap 'rm -f "$TMP_INNER"' EXIT

cat > "$TMP_INNER" <<EOF
set -euo pipefail
cd /home/builder/sdk

{
  echo "src-link local /feed"
  cat feeds.conf.default
} > feeds.conf

# Retry feeds update -- git.openwrt.org TLS is flaky. Clear feeds CONTENTS
# rather than the directory itself; in CI the dir may be a bind-mount from
# the host-side actions cache and rm-ing the mount point fails.
attempt=0
until ./scripts/feeds update -a; do
  attempt=\$((attempt + 1))
  if [ "\$attempt" -ge 4 ]; then
    echo "feeds update failed after \$attempt attempts" >&2
    exit 1
  fi
  echo "feeds update attempt \$attempt failed; retrying after \$((attempt * 5))s" >&2
  ( cd feeds && rm -rf -- * .[!.]* ..?* 2>/dev/null || true )
  sleep \$((attempt * 5))
done
# Install only the feeds we need: local (this repo's packages) and base
# (libuv, libopenssl, etc. for ZET runtime deps). We do NOT install
# packages, luci, telephony, or routing -- those would pull in 200+
# unrelated .ipks during make defconfig.
./scripts/feeds install -p local -a
./scripts/feeds install -p base -a
# Allow individual deps from packages/luci feeds without enabling them
# wholesale.
./scripts/feeds install libsodium libprotobuf-c libpcap libuv libjson-c llhttp stc luci-base 2>/dev/null || true

# Start from an empty .config so make defconfig only enables what our
# package selects via DEPENDS (and the SDK target itself).
: > .config
echo "CONFIG_ALL=n" >> .config
echo "CONFIG_ALL_KMODS=n" >> .config
echo "CONFIG_ALL_NONSHARED=n" >> .config
echo "CONFIG_AUTOREMOVE=y" >> .config
echo "CONFIG_PACKAGE_$PACKAGE=m" >> .config

make defconfig
make package/$PACKAGE/compile V=s -j"\$(nproc)"

mkdir -p /out
find bin/ -name "*.ipk" -print -exec cp {} /out/ \;
EOF

# mktemp creates the file mode 0600 owned by the host user. The SDK image
# runs the inner script as the unprivileged 'builder' user (uid 1000), and
# on Linux Docker the host uid is preserved -- so a 0600 file owned by
# host uid 1001 (typical CI runner) is unreadable to container uid 1000.
# Make it world-readable. The contents are not secret.
chmod 0644 "$TMP_INNER"

echo "==> Running build in container"
docker run --rm \
  -v "$FEED_PATH:/feed:ro" \
  -v "$OUT_DIR:/out" \
  -v "$TMP_INNER:/tmp/build-inner.sh:ro" \
  "${FEEDS_MOUNT_ARG[@]}" \
  "$IMAGE_TAG" \
  bash /tmp/build-inner.sh

echo "==> Produced .ipk(s):"
ls -la "$OUT_DIR"/*.ipk
