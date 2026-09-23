#!/bin/bash
# SD カードの boot partition で、次回起動時の USB モードを HOST / NCM から選択する。
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=sd/lib/sd_card.sh
. "$SCRIPT_DIR/lib/sd_card.sh"

usage()
{
    printf '使用方法: sudo bash %s DEVICE {host|ncm}\n' "$0" >&2
    printf '例: sudo bash %s /dev/sdX ncm\n' "$0" >&2
    exit 2
}

[ "$#" -eq 2 ] || usage

case "${2,,}" in
host)
    MODE_LABEL=HOST
    SOURCE_NAME=imx28-pwsh6-host.dtb
    ;;
ncm)
    MODE_LABEL=NCM
    SOURCE_NAME=imx28-pwsh6-peripheral.dtb
    ;;
*)
    usage
    ;;
esac

sd_require_root
sd_require_commands lsblk readlink mountpoint findmnt mount umount cp mv sync mktemp rmdir mkdir

DEV=$(sd_resolve_device "$1")
PART_BOOT=$(sd_partition_path "$DEV" 1)

sd_validate_partition "$DEV" "$PART_BOOT"
sd_reject_critical_mounts "$DEV"
sd_require_label "$PART_BOOT" boot

sd_confirm_device "$DEV" "$PART_BOOT の次回起動時 USB モードを $MODE_LABEL に切り替えます"
sd_unmount_partition "$PART_BOOT"

WORK_DIR=$(mktemp -d /tmp/nerves-brain-usb-mode.XXXXXX)
MNT_BOOT="$WORK_DIR/boot"
mkdir -p -- "$MNT_BOOT"
sd_register_cleanup_dir "$WORK_DIR"
sd_register_cleanup_dir "$MNT_BOOT"
sd_install_cleanup_trap

sd_mount_partition "$PART_BOOT" "$MNT_BOOT"
sd_assert_mount_source "$PART_BOOT" "$MNT_BOOT"

SOURCE_PATH="$MNT_BOOT/$SOURCE_NAME"
TARGET_PATH="$MNT_BOOT/imx28-pwsh6.dtb"
TEMP_PATH="$TARGET_PATH.new"

[ -f "$SOURCE_PATH" ] ||
    sd_die "$SOURCE_NAME が boot partition にありません。現在の firmware で mix burn をやり直してください"

cp -f -- "$SOURCE_PATH" "$TEMP_PATH"
sync
mv -f -- "$TEMP_PATH" "$TARGET_PATH"
sync

sd_finish_cleanup
printf '完了: 次回起動時の USB モードを %s に設定しました。\n' "$MODE_LABEL"
