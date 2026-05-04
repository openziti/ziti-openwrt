#!/usr/bin/env bash
# merge-artifacts.sh -- the workflow's download-artifact step lays out every
# uploaded artifact under <raw>/<artifact-name>/. We have:
#
#   ipks-aarch64_cortex-a53/        # sdk job, ZET + llhttp9
#   ipks-x86_64/                    # sdk job, ZET + llhttp9
#   ipks-router-aarch64_cortex-a53/ # router job, ziti-router
#   ipks-router-x86_64/             # router job, ziti-router
#   ipks-luci/                      # arch-independent luci-app-ziti
#
# publish-feed-ci.sh expects:
#
#   <merged>/aarch64_cortex-a53/*.ipk
#   <merged>/x86_64/*.ipk
#   <merged>/luci/*.ipk
#
# This script merges the former into the latter. Idempotent.
#
# Usage: tools/merge-artifacts.sh <raw-dir> <merged-dir>

set -euo pipefail

RAW="${1:?usage: $0 <raw-dir> <merged-dir>}"
MERGED="${2:?usage: $0 <raw-dir> <merged-dir>}"

rm -rf "$MERGED"
mkdir -p "$MERGED"

shopt -s nullglob
for d in "$RAW"/*/; do
    name=$(basename "$d")
    case "$name" in
        ipks-luci)
            mkdir -p "$MERGED/luci"
            cp -f "$d"*.ipk "$MERGED/luci/" 2>/dev/null || true
            ;;
        ipks-router-*)
            target="${name#ipks-router-}"
            mkdir -p "$MERGED/$target"
            cp -f "$d"*.ipk "$MERGED/$target/" 2>/dev/null || true
            ;;
        ipks-*)
            target="${name#ipks-}"
            mkdir -p "$MERGED/$target"
            cp -f "$d"*.ipk "$MERGED/$target/" 2>/dev/null || true
            ;;
        *)
            echo "WARN: unrecognized artifact dir $name; skipping" >&2
            ;;
    esac
done

echo "==> Merged layout:"
find "$MERGED" -name '*.ipk' -printf '  %p\n' | sort
