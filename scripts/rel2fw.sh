#!/usr/bin/env bash
# Build a Brain firmware bundle by merging the Nerves release into an ext4
# rootfs image. This keeps the public rel2fw.sh command-line contract that the
# Nerves Mix firmware task expects, but avoids the stock squashfs merge path.
set -e

PWD=${PWD:-$(pwd)}
BUILD_DIR=${MIX_BUILD_PATH:-$(pwd)/_build}
PROJECT_DIR=$(basename "$PWD")
SCRIPT_NAME=$0

if [[ -z "$NERVES_SYSTEM" ]]; then
    echo "$SCRIPT_NAME: Source nerves-env.sh and try again."
    exit 1
fi

TMP_DIR=$BUILD_DIR/_nerves-tmp
rm -fr "$TMP_DIR"
mkdir -p "$TMP_DIR"

cleanup() {
    if [[ "$NERVES_DEBUG" == "1" ]]; then
        echo "$SCRIPT_NAME: NERVES_DEBUG is set. Leaving $TMP_DIR for inspection."
    else
        rm -fr "$TMP_DIR"
    fi
}
trap cleanup EXIT

usage() {
    echo "Usage: $SCRIPT_NAME [options] <Release directory>"
    echo
    echo "Options:"
    echo "  -a <path to rootfs overlay> May be supplied multiple times."
    echo "  -c <fwup.conf>             Default is $NERVES_SDK_IMAGES/fwup.conf"
    echo "  -f <firmware output file>  Default is $PROJECT_DIR.fw"
    echo "  -o <image output file>     Default is $PROJECT_DIR.img"
    echo "  -p <file priorities>       Accepted for compatibility; ignored for ext4."
    echo "  -s <script path>           Post-processing script for rootfs (optional)"
}

while getopts "a:c:f:o:p:s:" opt; do
    case $opt in
        a)
            ROOTFS_OVERLAYS="$ROOTFS_OVERLAYS $OPTARG"
            ;;
        c)
            FWUP_CONFIG="$OPTARG"
            ;;
        f)
            FW_FILENAME="$OPTARG"
            ;;
        o)
            IMG_FILENAME="$OPTARG"
            ;;
        p)
            ;;
        s)
            POST_PROCESSING_SCRIPT="$OPTARG"
            ;;
        \?)
            echo "$SCRIPT_NAME: ERROR: Invalid option: -$OPTARG"
            usage
            exit 1
            ;;
        :)
            echo "$SCRIPT_NAME: ERROR: Option -$OPTARG requires an argument."
            usage
            exit 1
            ;;
    esac
done
shift $((OPTIND - 1))

if [[ $# -lt 1 ]]; then
    echo "$SCRIPT_NAME: ERROR: Expecting release directory"
    usage
    exit 1
fi

RELEASE_DIR=$1

FWUP=$NERVES_TOOLCHAIN/bin/fwup
[[ -e "$FWUP" ]] || FWUP=$(command -v fwup || echo "/usr/bin/fwup")
if [[ ! -e "$FWUP" ]]; then
    echo "$SCRIPT_NAME: ERROR: Please install fwup first"
    exit 1
fi

MKE2FS=$NERVES_TOOLCHAIN/sbin/mke2fs
[[ -e "$MKE2FS" ]] || MKE2FS=$(command -v mke2fs || echo "/sbin/mke2fs")
if [[ ! -e "$MKE2FS" ]]; then
    echo "$SCRIPT_NAME: ERROR: Please install mke2fs first"
    exit 1
fi

[[ -z "$FW_FILENAME" ]] && FW_FILENAME=${PROJECT_DIR}.fw
[[ -z "$FWUP_CONFIG" ]] && FWUP_CONFIG=$NERVES_SDK_IMAGES/fwup.conf
ROOTFS_TAR=$NERVES_SDK_IMAGES/rootfs.tar
ROOTFS_SIZE=${NERVES_BRAIN_ROOTFS_SIZE:-256M}
BRAIN_BOOT_DIR=${BRAIN_BOOT_DIR:-"$NERVES_SYSTEM/boot"}
BOOT_ASSET_FETCHER=$NERVES_SYSTEM/scripts/fetch_boot_assets.sh

if [[ ! -f "$ROOTFS_TAR" ]]; then
    echo "$SCRIPT_NAME: ERROR: Missing base rootfs tarball: $ROOTFS_TAR"
    exit 1
fi

if [[ ! -d "$RELEASE_DIR/lib" || ! -d "$RELEASE_DIR/releases" ]]; then
    echo "$SCRIPT_NAME: ERROR: Expecting '$RELEASE_DIR' to contain 'lib' and 'releases' subdirectories"
    exit 1
fi

if [[ ! -x "$BOOT_ASSET_FETCHER" ]]; then
    echo "$SCRIPT_NAME: ERROR: Missing boot asset fetcher: $BOOT_ASSET_FETCHER"
    exit 1
fi

if [[ ! -f "$BRAIN_BOOT_DIR/edsh6exe.bin" || ! -f "$BRAIN_BOOT_DIR/zImage" || ! -f "$BRAIN_BOOT_DIR/imx28-pwsh6.dtb" ]]; then
    echo "Fetching pinned brain-hackers boot assets into $BRAIN_BOOT_DIR..."
    "$BOOT_ASSET_FETCHER" "$BRAIN_BOOT_DIR"
fi

mkdir -p "$(dirname "$FW_FILENAME")"

echo "Updating base ext4 rootfs image with Erlang release..."

COMBINED_TAR=$TMP_DIR/combined-rootfs.tar
RELEASE_COPY=$TMP_DIR/release
TAR_ROOT=$TMP_DIR/tar-root

cp "$ROOTFS_TAR" "$COMBINED_TAR"
mkdir -p "$RELEASE_COPY" "$TAR_ROOT/srv/erlang"
cp -a "$RELEASE_DIR/." "$RELEASE_COPY"

"$NERVES_SYSTEM/scripts/scrub-otp-release.sh" "$RELEASE_COPY"

tar --append --file "$COMBINED_TAR" --numeric-owner --owner=0 --group=0 \
    -C "$TAR_ROOT" ./srv ./srv/erlang
tar --append --file "$COMBINED_TAR" --numeric-owner --owner=0 --group=0 \
    -C "$RELEASE_COPY" --transform='s#^\.#./srv/erlang#' .

SYSTEM_ROOTFS_OVERLAY=$NERVES_SYSTEM/rootfs_overlay

if [[ -d "$SYSTEM_ROOTFS_OVERLAY" ]]; then
    echo "Copying system rootfs_overlay: $SYSTEM_ROOTFS_OVERLAY"
    tar --append --file "$COMBINED_TAR" --numeric-owner --owner=0 --group=0 \
        -C "$SYSTEM_ROOTFS_OVERLAY" .
fi

if [[ "$ROOTFS_OVERLAYS" ]]; then
    for OVERLAY in $ROOTFS_OVERLAYS; do
        if [[ -d $OVERLAY ]]; then
            echo "Copying rootfs_overlay: $OVERLAY"
            tar --append --file "$COMBINED_TAR" --numeric-owner --owner=0 --group=0 \
                -C "$OVERLAY" .
        elif [[ -n "$OVERLAY" ]]; then
            echo "rootfs_overlay: $OVERLAY does not exist!"
            exit 1
        fi
    done
fi

ROOTFS_IMG=$TMP_DIR/combined.ext4
truncate -s "$ROOTFS_SIZE" "$ROOTFS_IMG"
"$MKE2FS" -q -t ext4 -L rootfs -d "$COMBINED_TAR" "$ROOTFS_IMG"

if [[ -n "${POST_PROCESSING_SCRIPT}" ]]; then
    echo "Running post-processing script: ${POST_PROCESSING_SCRIPT}"
    "${POST_PROCESSING_SCRIPT}" "$ROOTFS_IMG"
fi

echo "Building $FW_FILENAME..."
BRAIN_BOOT_DIR="$BRAIN_BOOT_DIR" ROOTFS="$ROOTFS_IMG" "$FWUP" -c -f "$FWUP_CONFIG" -o "$FW_FILENAME"

metadata=$("$FWUP" -m -i "$FW_FILENAME")
if [[ $metadata =~ meta-uuid=\"([^\"]+)\" ]]; then
    metadata_uuid="${BASH_REMATCH[1]}"
    if [[ $metadata =~ meta-nickname=\"([^\"]+)\" ]]; then
        metadata_nickname="${BASH_REMATCH[1]}"
        echo "Firmware UUID: $metadata_nickname ($metadata_uuid)"
    else
        echo "Firmware UUID: $metadata_uuid"
    fi
fi

if [[ -n "$IMG_FILENAME" ]]; then
    mkdir -p "$(dirname "$IMG_FILENAME")"
    rm -f "$IMG_FILENAME"
    touch "$IMG_FILENAME"
    echo "Building $IMG_FILENAME..."
    "$FWUP" -a -d "$IMG_FILENAME" -t complete -i "$FW_FILENAME"
fi
