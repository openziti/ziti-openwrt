#!/usr/bin/env bash
# build-ziti-router.sh -- compile the openziti `ziti` Go binary as a
# fully-static, musl-friendly executable for arm64 and amd64. Stages
# the results into package/ziti-router/files/binaries/ where the
# OpenWRT package picks them up.
#
# Why we build it ourselves: upstream releases use CGO_ENABLED=1 and
# link glibc. OpenWRT is musl. ziti has no `import "C"` requirements,
# so building with CGO_ENABLED=0 produces a portable static binary.
#
# Requires: docker, internet access (pulls golang:1.26 + module cache).
# Wall time: ~5-10 min per arch on first run, ~1-2 min thereafter.
#
# Usage: bash tools/build-ziti-router.sh [-v <ziti-version>]

set -euo pipefail

ZITI_VERSION="1.6.15"

while getopts "v:" opt; do
    case "$opt" in
        v) ZITI_VERSION="$OPTARG" ;;
        *) echo "usage: $0 [-v <ziti-version>]" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$REPO_ROOT/build/ziti-src-v$ZITI_VERSION"
OUT_DIR="$REPO_ROOT/package/ziti-router/files/binaries"

mkdir -p "$WORK_DIR" "$OUT_DIR"

# Fetch source if we don't have it.
if [ ! -f "$WORK_DIR/.fetched" ]; then
    tarball="$WORK_DIR/ziti-source.tar.gz"
    echo "==> Downloading ziti v$ZITI_VERSION source..."
    curl -sSL -o "$tarball" \
        "https://github.com/openziti/ziti/releases/download/v${ZITI_VERSION}/source-v${ZITI_VERSION}.tar.gz"
    rm -rf "$WORK_DIR/src"
    mkdir -p "$WORK_DIR/src"
    tar -xzf "$tarball" -C "$WORK_DIR/src" --strip-components=1
    touch "$WORK_DIR/.fetched"
fi

build_one() {
    local goarch="$1" outname="$2"
    echo "==> Building ziti for linux/$goarch -> $outname"
    # MSYS_NO_PATHCONV avoids Git-Bash translating /src into a Windows
    # path before docker sees the arg. The src-side path is the host's
    # absolute Windows path (D:/...) on Windows or POSIX on Linux/Mac.
    local src_abs
    src_abs=$(cd "$WORK_DIR/src" && pwd -W 2>/dev/null || pwd)
    MSYS_NO_PATHCONV=1 docker run --rm \
        -v "${src_abs}:/src" \
        -w /src \
        -e CGO_ENABLED=0 \
        -e GOOS=linux \
        -e GOARCH="$goarch" \
        golang:1.26 \
        go build -trimpath -ldflags="-s -w" -o "/src/build-out/$outname" ./ziti
    cp "$WORK_DIR/src/build-out/$outname" "$OUT_DIR/$outname"
    echo "==> Wrote $OUT_DIR/$outname"
}

build_one arm64 ziti-arm64
build_one amd64 ziti-amd64

echo
echo "==> Verification:"
for f in "$OUT_DIR"/ziti-*; do
    echo "  $f:"
    file "$f" | sed 's/^/    /'
done
