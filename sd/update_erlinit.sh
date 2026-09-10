#!/bin/bash
# SD カード上の erlinit.config に USB NCM の起動処理を追加する。
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
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
sd_require_commands lsblk readlink mountpoint findmnt mount umount sync mktemp rmdir mkdir grep cat

DEV=$(sd_resolve_device "$1")
PART_ROOT=$(sd_partition_path "$DEV" 2)
sd_validate_partition "$DEV" "$PART_ROOT"
sd_reject_critical_mounts "$DEV"
sd_require_label "$PART_ROOT" rootfs

sd_confirm_device "$DEV" "$PART_ROOT の erlinit.config を更新します"
sd_unmount_partition "$PART_ROOT"
sd_validate_partition "$DEV" "$PART_ROOT"
sd_require_label "$PART_ROOT" rootfs

WORK_DIR=$(mktemp -d /tmp/nerves-brain-erlinit.XXXXXX)
MNT_ROOT="$WORK_DIR/root"
mkdir -p -- "$MNT_ROOT"
sd_register_cleanup_dir "$WORK_DIR"
sd_register_cleanup_dir "$MNT_ROOT"
sd_install_cleanup_trap

sd_mount_partition "$PART_ROOT" "$MNT_ROOT"
sd_assert_mount_source "$PART_ROOT" "$MNT_ROOT"

CONFIG_FILE="$MNT_ROOT/etc/erlinit.config"
[ -f "$CONFIG_FILE" ] || sd_die "erlinit.config が見つかりません: $CONFIG_FILE"
if ! grep -q -- 'pre-run-exec' "$CONFIG_FILE"; then
	cat >>"$CONFIG_FILE" <<'EOF'

# Erlang の起動前に USB NCM gadget を有効にする
--pre-run-exec /usr/bin/enable_ethernet_gadget
EOF
fi
printf '%s\n' '--- erlinit.config ---'
cat "$CONFIG_FILE"

sync
sd_finish_cleanup
printf '完了: SD カードを取り外し、SHARP Brain をリセットしてください。\n'
