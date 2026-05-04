#!/usr/bin/env bash
# collect-ipks.sh -- copy just the openziti .ipks (and the luci _all .ipk)
# out of the SDK build's per-target output directory into a clean
# build/collect/<target>/ that the workflow uploads as an artifact.
#
# The SDK `make defconfig` step pulls ~200 unrelated .ipks (kmods,
# linux-firmware, etc.) into build/<target>/. We do not want those in the
# uploaded artifact -- they bloat the artifact and would end up in the
# public feed if we were sloppy.
#
# Usage: tools/collect-ipks.sh <target>

set -euo pipefail

TARGET="${1:?usage: $0 <target>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC="$REPO_ROOT/build/$TARGET"
DST="$REPO_ROOT/build/collect/$TARGET"
LUCI_DST="$REPO_ROOT/build/collect/luci"

mkdir -p "$DST" "$LUCI_DST"

# Per-target packages.
for pat in 'ziti-edge-tunnel_*.ipk' 'llhttp9_*.ipk' 'ziti-router_*.ipk'; do
    for f in "$SRC"/$pat; do
        [ -f "$f" ] || continue
        # Skip the _all luci package if it ended up in here -- handled below.
        case "$(basename "$f")" in
            *_all.ipk) continue ;;
        esac
        cp -f "$f" "$DST/"
        echo "  collected $(basename "$f")"
    done
done

# luci-app-ziti is _all and lives once under build/collect/luci/.
for f in "$SRC"/luci-app-ziti_*_all.ipk; do
    [ -f "$f" ] || continue
    cp -f "$f" "$LUCI_DST/"
    echo "  collected (luci) $(basename "$f")"
done

echo "==> wrote $(ls -1 "$DST" 2>/dev/null | wc -l) ipks to $DST"
