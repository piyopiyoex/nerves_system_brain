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
require_file "$REPO_ROOT/boot/uEnv.a.txt"
require_file "$REPO_ROOT/boot/uEnv.b.txt"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/nerves-brain-fwup.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT

system_dir="$work_dir/system"
firmware="$work_dir/test.fw"
disk_image="$work_dir/disk.img"
active_dtb="$work_dir/active.dtb"
boot_file="$work_dir/boot-file"
upgrade_log="$work_dir/upgrade.log"

mkdir -p -- "$system_dir/images" "$system_dir/boot"
printf 'ci-rootfs\n' > "$system_dir/images/rootfs.squashfs"
cp -- "$REPO_ROOT/boot/imx28-pwsh6-peripheral.dtb" \
    "$system_dir/boot/imx28-pwsh6-peripheral.dtb"
cp -- "$REPO_ROOT/boot/uEnv.a.txt" "$system_dir/boot/uEnv.a.txt"
cp -- "$REPO_ROOT/boot/uEnv.b.txt" "$system_dir/boot/uEnv.b.txt"

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
for task in complete usb_host usb_ncm upgrade.a upgrade.b upgrade.unsupported; do
    printf '%s\n' "$tasks" | grep -Fxq "$task" || {
        printf 'error: fwup task not found: %s\n' "$task" >&2
        exit 1
    }
done

# p1 starts at block 2048; p2/p3 are 256 MiB each. p4 has a 256 MiB
# minimum and expands to the remaining media capacity on real devices.
boot_offset_bytes=$((2048 * 512))
disk_size_bytes=$(((2048 + 131072 + 524288 + 524288 + 524288) * 512))
truncate -s "$disk_size_bytes" "$disk_image"

extract_boot_file()
{
    local name=$1
    local destination=$2

    rm -f -- "$destination"
    mcopy -i "${disk_image}@@${boot_offset_bytes}" "::$name" "$destination"
}

assert_boot_file_matches()
{
    local name=$1
    local expected=$2
    local description=$3

    extract_boot_file "$name" "$boot_file"
    if ! cmp -s "$boot_file" "$expected"; then
        printf 'error: %s does not match expected content\n' "$description" >&2
        exit 1
    fi
}

assert_active_dtb()
{
    local expected=$1
    local mode=$2

    extract_boot_file imx28-pwsh6.dtb "$active_dtb"
    if ! cmp -s "$active_dtb" "$expected"; then
        printf 'error: active DTB does not match %s mode reference\n' "$mode" >&2
        exit 1
    fi
}

printf '==> complete selects slot A and HOST\n'
fwup -a -d "$disk_image" -i "$firmware" -t complete
assert_active_dtb "$REPO_ROOT/boot/imx28-pwsh6.dtb" HOST
assert_boot_file_matches uEnv.a.txt "$REPO_ROOT/boot/uEnv.a.txt" 'slot A selector reference'
assert_boot_file_matches uEnv.b.txt "$REPO_ROOT/boot/uEnv.b.txt" 'slot B selector reference'
assert_boot_file_matches uEnv.txt "$REPO_ROOT/boot/uEnv.a.txt" 'active slot selector'

printf '==> usb_ncm selects peripheral DTB without changing slot selector\n'
fwup -a -d "$disk_image" -i "$firmware" -t usb_ncm
assert_active_dtb "$REPO_ROOT/boot/imx28-pwsh6-peripheral.dtb" NCM
assert_boot_file_matches uEnv.txt "$REPO_ROOT/boot/uEnv.a.txt" 'active slot selector after usb_ncm'

printf '==> usb_host restores HOST DTB without changing slot selector\n'
fwup -a -d "$disk_image" -i "$firmware" -t usb_host
assert_active_dtb "$REPO_ROOT/boot/imx28-pwsh6.dtb" HOST
assert_boot_file_matches uEnv.txt "$REPO_ROOT/boot/uEnv.a.txt" 'active slot selector after usb_host'

# The real upgrade.a/upgrade.b tasks require / to be mounted from a PW-SH6
# rootfs slot. On the CI host they must fall through to the explicit guard task.
printf '==> upgrade prefix rejects non-target host context\n'
if fwup -a -d "$disk_image" -i "$firmware" -t upgrade >"$upgrade_log" 2>&1; then
    printf 'error: upgrade unexpectedly succeeded outside a PW-SH6 rootfs slot\n' >&2
    exit 1
fi
grep -Fq 'mix upload must run on a PW-SH6 booted from the current A/B + application-data layout' "$upgrade_log" || {
    cat "$upgrade_log" >&2
    printf 'error: upgrade guard did not report the expected message\n' >&2
    exit 1
}

printf 'fwup task checks passed.\n'
