#!/usr/bin/env bash
# Exercise fwup.conf tasks against a temporary disk image without real hardware.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

require_command()
{
    command -v "$1" >/dev/null 2>&1 || {
        printf 'error: required command not found: %s\n' "$1" >&2
        exit 1
    }
}

require_file()
{
    [ -s "$1" ] || {
        printf 'error: required file not found or empty: %s\n' "$1" >&2
        exit 1
    }
}

require_command fwup
require_command mcopy
require_command cmp
require_command grep
require_command mktemp
require_command truncate
require_command cp
require_command printf
require_command rm

require_file "$REPO_ROOT/boot/edsh6exe.bin"
require_file "$REPO_ROOT/boot/zImage"
require_file "$REPO_ROOT/boot/imx28-pwsh6.dtb"
require_file "$REPO_ROOT/boot/imx28-pwsh6-peripheral.dtb"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/nerves-brain-fwup.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT

system_dir="$work_dir/system"
firmware="$work_dir/test.fw"
disk_image="$work_dir/disk.img"
active_dtb="$work_dir/active.dtb"

mkdir -p -- "$system_dir/images" "$system_dir/boot"
printf 'ci-rootfs\n' > "$system_dir/images/rootfs.squashfs"
cp -- "$REPO_ROOT/boot/imx28-pwsh6-peripheral.dtb" \
    "$system_dir/boot/imx28-pwsh6-peripheral.dtb"

NERVES_SYSTEM="$system_dir"
BRAIN_BOOT_DIR="$REPO_ROOT/boot"
NERVES_SDK_VERSION=ci
NERVES_FW_VCS_IDENTIFIER=ci
NERVES_FW_MISC=ci
export NERVES_SYSTEM BRAIN_BOOT_DIR NERVES_SDK_VERSION
export NERVES_FW_VCS_IDENTIFIER NERVES_FW_MISC

printf '==> create fwup archive\n'
fwup -c -f "$REPO_ROOT/fwup.conf" -o "$firmware"

printf '==> available fwup tasks\n'
tasks=$(fwup -l -i "$firmware")
printf '%s\n' "$tasks"
for task in complete upgrade usb_host usb_ncm; do
    printf '%s\n' "$tasks" | grep -Fxq "$task" || {
        printf 'error: fwup task not found: %s\n' "$task" >&2
        exit 1
    }
done

# p1 begins at block 2048; p2 ends at block 657408.
boot_offset_bytes=$((2048 * 512))
disk_size_bytes=$(((2048 + 131072 + 524288) * 512))
truncate -s "$disk_size_bytes" "$disk_image"

extract_active_dtb()
{
    rm -f -- "$active_dtb"
    mcopy -i "${disk_image}@@${boot_offset_bytes}" \
        ::imx28-pwsh6.dtb "$active_dtb"
}

assert_active_dtb()
{
    local expected=$1
    local mode=$2

    extract_active_dtb
    if ! cmp -s "$active_dtb" "$expected"; then
        printf 'error: active DTB does not match %s mode reference\n' "$mode" >&2
        exit 1
    fi
}

printf '==> complete selects HOST\n'
fwup -a -d "$disk_image" -i "$firmware" -t complete
assert_active_dtb "$REPO_ROOT/boot/imx28-pwsh6.dtb" HOST

printf '==> usb_ncm selects peripheral DTB\n'
fwup -a -d "$disk_image" -i "$firmware" -t usb_ncm
assert_active_dtb "$REPO_ROOT/boot/imx28-pwsh6-peripheral.dtb" NCM

printf '==> usb_host restores HOST DTB\n'
fwup -a -d "$disk_image" -i "$firmware" -t usb_host
assert_active_dtb "$REPO_ROOT/boot/imx28-pwsh6.dtb" HOST

printf 'fwup task checks passed.\n'
