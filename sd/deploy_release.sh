#!/bin/bash
# Elixir application release を SD カードの /srv/erlang へ配置する。
# release のビルドや更新方式はアプリケーション側で管理する。
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=sd/lib/sd_card.sh
. "$SCRIPT_DIR/lib/sd_card.sh"

usage()
{
	printf '使用方法: sudo bash %s DEVICE RELEASE_DIR\n' "$0" >&2
	printf '例: sudo bash %s /dev/sdX /path/to/release\n' "$0" >&2
	exit 2
}

[ "$#" -eq 2 ] || usage

sd_require_root
sd_require_commands lsblk readlink mountpoint findmnt mount umount cp sync du mktemp rmdir mkdir rm cut

DEV=$(sd_resolve_device "$1")
PART_ROOT=$(sd_partition_path "$DEV" 2)
sd_validate_partition "$DEV" "$PART_ROOT"
sd_reject_critical_mounts "$DEV"
sd_require_label "$PART_ROOT" rootfs

RELEASE_INPUT=$2
[ -d "$RELEASE_INPUT" ] || sd_die "リリースディレクトリが見つかりません: $RELEASE_INPUT"
RELEASE_DIR=$(readlink -f -- "$RELEASE_INPUT")
[ -d "$RELEASE_DIR/releases" ] || sd_die "有効なリリースではありません: $RELEASE_DIR"

sd_confirm_device "$DEV" "$PART_ROOT の /srv/erlang を指定したリリースで置き換えます"
sd_unmount_partition "$PART_ROOT"
sd_validate_partition "$DEV" "$PART_ROOT"
sd_require_label "$PART_ROOT" rootfs

WORK_DIR=$(mktemp -d /tmp/nerves-brain-release.XXXXXX)
MNT_ROOT="$WORK_DIR/root"
mkdir -p -- "$MNT_ROOT"
sd_register_cleanup_dir "$WORK_DIR"
sd_register_cleanup_dir "$MNT_ROOT"
sd_install_cleanup_trap

sd_mount_partition "$PART_ROOT" "$MNT_ROOT"
sd_assert_mount_source "$PART_ROOT" "$MNT_ROOT"

TARGET_DIR="$MNT_ROOT/srv/erlang"
rm -rf -- "$TARGET_DIR"
mkdir -p -- "$TARGET_DIR"
cp -a "$RELEASE_DIR/." "$TARGET_DIR/"
printf 'リリースを配置しました: %s\n' "$(du -sh "$TARGET_DIR" | cut -f1)"

sync
sd_finish_cleanup
printf '完了: SD カードを取り外し、SHARP Brain をリセットしてください。\n'
