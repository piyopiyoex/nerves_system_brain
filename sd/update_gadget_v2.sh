#!/bin/bash
# USB NCM の起動スクリプトと lns を SD カードの p2 へ配置する。
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
sd_require_commands lsblk readlink mountpoint findmnt mount umount install sync mktemp rmdir mkdir

DEV=$(sd_resolve_device "$1")
PART_ROOT=$(sd_partition_path "$DEV" 2)
sd_validate_partition "$DEV" "$PART_ROOT"
sd_reject_critical_mounts "$DEV"
sd_require_label "$PART_ROOT" rootfs

GADGET_SOURCE="$REPO_ROOT/rootfs_overlay/usr/bin/enable_ethernet_gadget"
LNS_SOURCE="$REPO_ROOT/o/target/usr/bin/lns"
if [ ! -f "$LNS_SOURCE" ]; then
	LNS_SOURCE="$REPO_ROOT/rootfs_overlay/usr/bin/lns"
fi
[ -f "$GADGET_SOURCE" ] || sd_die "起動スクリプトが見つかりません: $GADGET_SOURCE"
[ -f "$LNS_SOURCE" ] || sd_die "lns が見つかりません。先に rootfs をビルドしてください"

sd_confirm_device "$DEV" "$PART_ROOT の USB NCM 起動ファイルを更新します"
sd_unmount_partition "$PART_ROOT"
sd_validate_partition "$DEV" "$PART_ROOT"
sd_require_label "$PART_ROOT" rootfs

WORK_DIR=$(mktemp -d /tmp/nerves-brain-gadget.XXXXXX)
MNT_ROOT="$WORK_DIR/root"
mkdir -p -- "$MNT_ROOT"
sd_register_cleanup_dir "$WORK_DIR"
sd_register_cleanup_dir "$MNT_ROOT"
sd_install_cleanup_trap

sd_mount_partition "$PART_ROOT" "$MNT_ROOT"
sd_assert_mount_source "$PART_ROOT" "$MNT_ROOT"
install -m 755 "$LNS_SOURCE" "$MNT_ROOT/usr/bin/lns"
install -m 755 "$GADGET_SOURCE" "$MNT_ROOT/usr/bin/enable_ethernet_gadget"
printf 'brain\n' >"$MNT_ROOT/etc/hostname"

sync
sd_finish_cleanup
printf '完了: SD カードを取り外し、SHARP Brain をリセットしてください。\n'
