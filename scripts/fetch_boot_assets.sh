#!/usr/bin/env bash
# Fetch the minimum fixed buildbrain assets needed for direct SD boot on PW-SH6.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

RELEASE_TAG=2026-03-25-024518
RELEASE_BASE_URL="https://github.com/brain-hackers/buildbrain/releases/download/$RELEASE_TAG"
LINUX_ARCHIVE="linux-$RELEASE_TAG.zip"
UBOOT_ARCHIVE="uboot-sh6-$RELEASE_TAG.zip"
LINUX_SHA256=da7a8f87c6daf982085c2f7042d874654645a28a6318558d3c6ea0e6a2851f69
UBOOT_SHA256=a07b43ade594b566ed189bcfc5e49212006679600ca30e2fb7468961ef664f95

usage()
{
    printf 'Usage: %s [OUTPUT_DIR]\n' "$0" >&2
    exit 2
}

if [ "$#" -gt 1 ]; then
    usage
fi

OUTPUT_DIR=${1:-"$REPO_ROOT/boot"}

require_command()
{
    command -v "$1" >/dev/null 2>&1 || {
        printf 'error: required command not found: %s\n' "$1" >&2
        exit 1
    }
}

verify_archive()
{
    local archive=$1
    local expected_sha256=$2
    local actual_sha256

    actual_sha256=$(sha256sum "$archive" | awk '{print $1}')
    [ "$actual_sha256" = "$expected_sha256" ] || {
        printf 'error: checksum mismatch for %s\n' "$archive" >&2
        exit 1
    }
}

require_command curl
require_command unzip
require_command sha256sum
require_command awk
require_command install
require_command mktemp
require_command rm

mkdir -p -- "$OUTPUT_DIR"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nerves-brain-boot.XXXXXX")
trap 'rm -rf -- "$WORK_DIR"' EXIT

LINUX_PATH="$WORK_DIR/$LINUX_ARCHIVE"
UBOOT_PATH="$WORK_DIR/$UBOOT_ARCHIVE"

curl --fail --location --retry 3 --output "$LINUX_PATH" "$RELEASE_BASE_URL/$LINUX_ARCHIVE"
curl --fail --location --retry 3 --output "$UBOOT_PATH" "$RELEASE_BASE_URL/$UBOOT_ARCHIVE"
verify_archive "$LINUX_PATH" "$LINUX_SHA256"
verify_archive "$UBOOT_PATH" "$UBOOT_SHA256"

unzip -p "$UBOOT_PATH" release/edsh6exe.bin > "$WORK_DIR/edsh6exe.bin"
unzip -p "$LINUX_PATH" release/zImage > "$WORK_DIR/zImage"
unzip -p "$LINUX_PATH" release/imx28-pwsh6.dtb > "$WORK_DIR/imx28-pwsh6.dtb"

for asset in edsh6exe.bin zImage imx28-pwsh6.dtb; do
    [ -s "$WORK_DIR/$asset" ] || {
        printf 'error: missing or empty extracted asset: %s\n' "$asset" >&2
        exit 1
    }
    install -m 0644 "$WORK_DIR/$asset" "$OUTPUT_DIR/$asset"
done

printf 'Fetched PW-SH6 boot assets into %s\n' "$OUTPUT_DIR"
