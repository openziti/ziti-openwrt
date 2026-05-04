#!/usr/bin/env bash
# publish-feed.sh -- in-container feed builder.
#
# Inputs (via env vars, set by publish-feed.ps1):
#   IPK_ROOT     -- directory containing <target>/*.ipk subdirs (mounted)
#   OUT_DIR      -- directory where the feed will be written (mounted rw)
#   SIGN_KEY     -- optional path to a usign secret key (mounted ro). Empty == no sign.
#   BASE_URL     -- optional, recorded in feed-info.json. Empty allowed.
#   REPACK_TO_ARCH -- optional, comma-separated list of "src:dst" arch pairs.
#                    For each pair, the per-target dir <src> staged in IPK_ROOT
#                    is mirrored to a sibling <dst> dir with each non-`all` ipk's
#                    inner control file rewritten so `Architecture: <src>`
#                    becomes `Architecture: <dst>`. `Architecture: all` ipks are
#                    copied through unchanged. The dst dir then gets its own
#                    Packages/Packages.gz/Packages.sig like any other target.
#                    Example: REPACK_TO_ARCH="aarch64_cortex-a53:aarch64_cortex-a53_neon-vfpv4"
#
# Produces:
#   $OUT_DIR/<target>/*.ipk
#   $OUT_DIR/<target>/Packages
#   $OUT_DIR/<target>/Packages.gz
#   $OUT_DIR/<target>/Packages.sig   (only if SIGN_KEY is set)
#   $OUT_DIR/feed-info.json

set -euo pipefail

: "${IPK_ROOT:?IPK_ROOT must be set}"
: "${OUT_DIR:?OUT_DIR must be set}"
SIGN_KEY="${SIGN_KEY:-}"
BASE_URL="${BASE_URL:-}"
REPACK_TO_ARCH="${REPACK_TO_ARCH:-}"

mkdir -p "$OUT_DIR"

# Repack one .ipk: rewrite the Architecture: line in inner control to $dst.
# Args: src_ipk dst_ipk src_arch dst_arch
# Mirrors the tar/sed/tar dance from docs/install-gl-inet.md.
repack_ipk() {
    local src="$1" dst="$2" src_arch="$3" dst_arch="$4"
    local tmp ctrlarch
    tmp=$(mktemp -d)
    # Outer .ipk is gzipped tar (modern OpenWRT 23.05) or ar archive (older).
    local magic
    magic=$(head -c 8 "$src" | od -An -c | head -n1 | tr -d ' \n')
    case "$magic" in
        \!\<arch\>*)
            (cd "$tmp" && ar x "$src")
            ;;
        *)
            tar -xzf "$src" -C "$tmp"
            ;;
    esac
    mkdir -p "$tmp/ctrl"
    tar -xzf "$tmp/control.tar.gz" -C "$tmp/ctrl"
    ctrlarch=$(awk -F': *' '/^Architecture:/ {print $2; exit}' "$tmp/ctrl/control")
    if [ "$ctrlarch" = "all" ]; then
        # No repack required for arch-independent packages; copy through.
        cp -f "$src" "$dst"
        rm -rf "$tmp"
        return 0
    fi
    sed -i "s/^Architecture: ${src_arch}\$/Architecture: ${dst_arch}/" "$tmp/ctrl/control"
    tar -czf "$tmp/control.tar.gz" -C "$tmp/ctrl" . --owner=0 --group=0
    # Re-roll outer tar. Modern OpenWRT format: gzipped tar of the three members.
    tar -czf "$dst" -C "$tmp" debian-binary control.tar.gz data.tar.gz --owner=0 --group=0
    rm -rf "$tmp"
}

# If REPACK_TO_ARCH is set, materialize sibling dirs into a writable staging
# area so the rest of the script picks them up via its normal IPK_ROOT walk.
# We point IPK_ROOT at a merged dir containing both the originals (symlinks)
# and the repacked siblings.
if [ -n "$REPACK_TO_ARCH" ]; then
    STAGE="$(mktemp -d -t feed-stage.XXXXXX)"
    mkdir -p "$STAGE"
    # Mirror original target dirs as symlinks (read-only).
    for tdir in "$IPK_ROOT"/*/; do
        name=$(basename "$tdir")
        ln -s "$tdir" "$STAGE/$name"
    done
    IFS=',' read -ra _pairs <<< "$REPACK_TO_ARCH"
    for pair in "${_pairs[@]}"; do
        src_arch="${pair%%:*}"
        dst_arch="${pair##*:}"
        if [ -z "$src_arch" ] || [ -z "$dst_arch" ] || [ "$src_arch" = "$pair" ]; then
            echo "WARN: malformed REPACK_TO_ARCH pair '$pair', skipping" >&2
            continue
        fi
        if [ ! -d "$IPK_ROOT/$src_arch" ]; then
            echo "WARN: REPACK_TO_ARCH src '$src_arch' has no dir under IPK_ROOT, skipping" >&2
            continue
        fi
        echo "[publish-feed] repacking $src_arch -> $dst_arch"
        mkdir -p "$STAGE/$dst_arch"
        for srcipk in "$IPK_ROOT/$src_arch"/*.ipk; do
            [ -f "$srcipk" ] || continue
            base=$(basename "$srcipk")
            # Rename arch tag in filename if it contains the src_arch suffix.
            newbase="${base/_${src_arch}.ipk/_${dst_arch}.ipk}"
            repack_ipk "$srcipk" "$STAGE/$dst_arch/$newbase" "$src_arch" "$dst_arch"
        done
    done
    IPK_ROOT="$STAGE"
fi

# Extract a single field from a Debian-style control file.
# Args: control_path field_name
control_field() {
    local file="$1" field="$2"
    awk -v f="$field" '
        BEGIN { IGNORECASE = 1 }
        /^[A-Za-z][A-Za-z0-9-]*:/ {
            split($0, kv, ":")
            key = kv[1]
            sub(/^[^:]*:[ \t]*/, "")
            val = $0
            current = key
            if (tolower(key) == tolower(f)) print val
        }
    ' "$file"
}

# Build the Packages stanza for one .ipk.
# Echoes the stanza on stdout. Args: ipk_path target_dir
emit_stanza() {
    local ipk="$1" tgtdir="$2"
    local base size sha tmp ctrl
    base=$(basename "$ipk")
    size=$(stat -c '%s' "$ipk")
    sha=$(sha256sum "$ipk" | awk '{print $1}')
    tmp=$(mktemp -d)
    # .ipk is either:
    #  - a gzipped tarball containing ./debian-binary, ./control.tar.gz,
    #    ./data.tar.gz (modern OpenWRT 23.05 ipkg-build), OR
    #  - a Debian-style ar archive (older OpenWRT and Debian).
    # Sniff the magic and dispatch.
    magic=$(head -c 8 "$ipk" | od -An -c | head -n1 | tr -d ' \n')
    case "$magic" in
        \!\<arch\>*)
            # ar archive
            (cd "$tmp" && ar x "$ipk" control.tar.gz)
            ;;
        *)
            # assume gzipped tar; extract control.tar.gz from it
            tar -xzf "$ipk" -C "$tmp" ./control.tar.gz
            ;;
    esac
    mkdir -p "$tmp/ctrl"
    tar -xzf "$tmp/control.tar.gz" -C "$tmp/ctrl"
    ctrl="$tmp/ctrl/control"
    if [ ! -f "$ctrl" ]; then
        # Some packages put control under ./control
        ctrl=$(find "$tmp/ctrl" -name control -type f | head -n1)
    fi
    if [ ! -f "$ctrl" ]; then
        echo "WARN: no control file in $ipk, skipping" >&2
        rm -rf "$tmp"
        return 0
    fi
    # Strip trailing blank lines and emit the control fields verbatim,
    # then append Filename, Size, SHA256sum.
    sed -e 's/[[:space:]]*$//' "$ctrl" | awk 'NF {p=1} p {print}'
    echo "Filename: $base"
    echo "Size: $size"
    echo "SHA256sum: $sha"
    echo ""
    rm -rf "$tmp"
}

targets_json=""
first_target=1

# Iterate target subdirs of IPK_ROOT that contain .ipk files.
shopt -s nullglob
for tdir in "$IPK_ROOT"/*/; do
    target=$(basename "$tdir")
    # Skip the feed dir itself if IPK_ROOT == parent of OUT_DIR.
    [ "$target" = "$(basename "$OUT_DIR")" ] && continue
    ipks=( "$tdir"*.ipk )
    [ ${#ipks[@]} -gt 0 ] || continue

    out_t="$OUT_DIR/$target"
    mkdir -p "$out_t"

    echo "[publish-feed] target=$target ipks=${#ipks[@]}"

    # Mirror .ipk files (copy, do not move).
    for ipk in "${ipks[@]}"; do
        cp -f "$ipk" "$out_t/"
    done

    # Build Packages.
    : > "$out_t/Packages"
    for ipk in "$out_t"/*.ipk; do
        emit_stanza "$ipk" "$out_t" >> "$out_t/Packages"
    done

    gzip -kf -n "$out_t/Packages"  # produces Packages.gz, deterministic-ish

    # Sign if requested.
    if [ -n "$SIGN_KEY" ]; then
        if [ ! -f "$SIGN_KEY" ]; then
            echo "WARN: SIGN_KEY=$SIGN_KEY not found, skipping signature" >&2
        else
            usign -S -m "$out_t/Packages" -s "$SIGN_KEY" -x "$out_t/Packages.sig"
            echo "[publish-feed] signed Packages for $target"
        fi
    else
        echo "WARN: no signing key supplied; feed will be unsigned (devices must opkg --force-signature)" >&2
    fi

    # Append to JSON targets array.
    pkg_count=${#ipks[@]}
    if [ $first_target -eq 1 ]; then
        first_target=0
    else
        targets_json+=","
    fi
    targets_json+="{\"name\":\"$target\",\"package_count\":$pkg_count,\"signed\":$([ -f "$out_t/Packages.sig" ] && echo true || echo false)}"
done

generated=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
base_url_json="null"
if [ -n "$BASE_URL" ]; then
    base_url_json="\"$BASE_URL\""
fi

cat > "$OUT_DIR/feed-info.json" <<EOF
{
  "generated": "$generated",
  "base_url": $base_url_json,
  "targets": [$targets_json]
}
EOF

echo "[publish-feed] wrote $OUT_DIR/feed-info.json"
