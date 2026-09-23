#!/bin/bash
# Legacy/recovery: SHARP Brain PW-SH6 の既存パーティションへ rootfs を配置する。
# p1: nk/ の内容を直下へコピーし、SD カードからの直接起動を有効にする。
# p2: ext4 で初期化し、Nerves rootfs と Erlang/OTP を配置する。
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=sd/lib/sd_card.sh
. "$SCRIPT_DIR/lib/sd_card.sh"

usage()
{
	printf '使用方法: sudo bash %s DEVICE [BUILD_DIR]\n' "$0" >&2
	printf '例: sudo bash %s /dev/sdX\n' "$0" >&2
	exit 2
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
	usage
fi

sd_require_root
sd_require_commands lsblk readlink mountpoint findmnt mount umount mkfs.ext4 tar cp sync du mktemp rmdir mkdir cut

DEV=$(sd_resolve_device "$1")
PART_BOOT=$(sd_partition_path "$DEV" 1)
PART_ROOT=$(sd_partition_path "$DEV" 2)
sd_validate_partition "$DEV" "$PART_BOOT"
sd_validate_partition "$DEV" "$PART_ROOT"
sd_reject_critical_mounts "$DEV"
sd_require_label "$PART_BOOT" boot

BUILD_INPUT=${2:-"$REPO_ROOT/o"}
[ -d "$BUILD_INPUT" ] || sd_die "ビルド出力ディレクトリが見つかりません: $BUILD_INPUT"
BUILD_DIR=$(readlink -f -- "$BUILD_INPUT")
[ -f "$BUILD_DIR/images/rootfs.tar" ] ||
	sd_die "rootfs.tar が見つかりません: $BUILD_DIR/images/rootfs.tar"
[ -d "$BUILD_DIR/staging/usr/lib/erlang" ] ||
	sd_die "Erlang/OTP が見つかりません: $BUILD_DIR/staging/usr/lib/erlang"

sd_confirm_device "$DEV" "$PART_ROOT を ext4 で初期化し、p1 と p2 の内容を更新します"

sd_unmount_partition "$PART_ROOT"
sd_unmount_partition "$PART_BOOT"

# 取り外しやデバイス名の変化を考慮し、初期化の直前にも確認する。
sd_validate_partition "$DEV" "$PART_BOOT"
sd_validate_partition "$DEV" "$PART_ROOT"
sd_require_label "$PART_BOOT" boot
sd_require_unmounted "$PART_ROOT"

WORK_DIR=$(mktemp -d /tmp/nerves-brain-sd.XXXXXX)
MNT_BOOT="$WORK_DIR/boot"
MNT_ROOT="$WORK_DIR/root"
mkdir -p -- "$MNT_BOOT" "$MNT_ROOT"
sd_register_cleanup_dir "$WORK_DIR"
sd_register_cleanup_dir "$MNT_BOOT"
sd_register_cleanup_dir "$MNT_ROOT"
sd_install_cleanup_trap

sd_mount_partition "$PART_BOOT" "$MNT_BOOT"
sd_assert_mount_source "$PART_BOOT" "$MNT_BOOT"
if [ -d "$MNT_BOOT/nk" ]; then
	NK_FILES=("$MNT_BOOT"/nk/*)
	if [ -e "${NK_FILES[0]}" ]; then
		cp -f "${NK_FILES[@]}" "$MNT_BOOT"/
		printf 'p1: nk/ の内容をコピーしました（SD カードからの直接起動を有効化）\n'
	fi
fi

mkfs.ext4 -q -L rootfs "$PART_ROOT"
sd_mount_partition "$PART_ROOT" "$MNT_ROOT"
sd_assert_mount_source "$PART_ROOT" "$MNT_ROOT"
tar -xf "$BUILD_DIR/images/rootfs.tar" -C "$MNT_ROOT"
cp -a "$BUILD_DIR/staging/usr/lib/erlang" "$MNT_ROOT/usr/lib/erlang"
printf 'p2: rootfs（%s）を書き込みました\n' "$(du -sh --exclude=lost+found "$MNT_ROOT" | cut -f1)"

sync
sd_finish_cleanup
printf '完了: SD カードを取り外し、SHARP Brain をリセットしてください。\n'
