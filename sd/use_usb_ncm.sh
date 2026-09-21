#!/bin/bash
# SD カードの boot partition を USB NCM 用の peripheral Device Tree に切り替える。
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=sd/lib/sd_card.sh
. "$SCRIPT_DIR/lib/sd_card.sh"

usage()
{
	printf '使用方法: sudo bash %s DEVICE\n' "$0" >&2
	printf '例: sudo bash %s /dev/sdX\n' "$0" >&2
	exit 2
}

[ "$#" -eq 1 ] || usage

sd_require_root
sd_require_commands lsblk readlink mountpoint findmnt mount umount cp sync mktemp rmdir mkdir

DEV=$(sd_resolve_device "$1")
PART_BOOT=$(sd_partition_path "$DEV" 1)
DTB_SOURCE="$REPO_ROOT/sd/imx28-pwsh6-peripheral.dtb"

sd_validate_partition "$DEV" "$PART_BOOT"
sd_reject_critical_mounts "$DEV"
sd_require_label "$PART_BOOT" boot
[ -f "$DTB_SOURCE" ] || sd_die "Device Tree が見つかりません: $DTB_SOURCE"

sd_confirm_device "$DEV" "$PART_BOOT を USB NCM (peripheral) 構成に切り替えます"
sd_unmount_partition "$PART_BOOT"

WORK_DIR=$(mktemp -d /tmp/nerves-brain-usb-ncm.XXXXXX)
MNT_BOOT="$WORK_DIR/boot"
mkdir -p -- "$MNT_BOOT"
sd_register_cleanup_dir "$WORK_DIR"
sd_register_cleanup_dir "$MNT_BOOT"
sd_install_cleanup_trap

sd_mount_partition "$PART_BOOT" "$MNT_BOOT"
sd_assert_mount_source "$PART_BOOT" "$MNT_BOOT"
cp -f -- "$DTB_SOURCE" "$MNT_BOOT/imx28-pwsh6.dtb"

sync
sd_finish_cleanup
printf '完了: USB NCM 用 Device Tree を配置しました。\n'
