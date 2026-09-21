#!/bin/bash
# SD カード操作用スクリプトで共通して使用する安全確認と後処理。

SD_CLEANUP_MOUNTS=()
SD_CLEANUP_DIRS=()
SD_EXIT_STATUS=0

sd_die()
{
	printf 'エラー: %s\n' "$*" >&2
	exit 1
}

sd_require_root()
{
	[ "$(id -u)" -eq 0 ] || sd_die "sudo を付けて実行してください"
}

sd_require_commands()
{
	local command_name

	for command_name in "$@"; do
		command -v "$command_name" >/dev/null 2>&1 ||
			sd_die "必要なコマンドが見つかりません: $command_name"
	done
}

sd_resolve_device()
{
	local requested_device=$1
	local device
	local device_type

	case "$requested_device" in
	/dev/*) ;;
	*) sd_die "デバイスは /dev/ 以下のパスで指定してください: $requested_device" ;;
	esac

	device=$(readlink -f -- "$requested_device") ||
		sd_die "デバイスを解決できません: $requested_device"
	[ -b "$device" ] || sd_die "ブロックデバイスではありません: $device"

	device_type=$(lsblk -dnro TYPE -- "$device")
	[ "$device_type" = "disk" ] ||
		sd_die "パーティションではなくディスク全体を指定してください: $device"

	printf '%s\n' "$device"
}

sd_partition_path()
{
	local device=$1
	local number=$2

	case "$device" in
	*[0-9]) printf '%sp%s\n' "$device" "$number" ;;
	*) printf '%s%s\n' "$device" "$number" ;;
	esac
}

sd_validate_partition()
{
	local device=$1
	local partition=$2
	local parent_name
	local parent_device

	[ -b "$partition" ] || sd_die "パーティションが見つかりません: $partition"
	[ "$(lsblk -dnro TYPE -- "$partition")" = "part" ] ||
		sd_die "通常のパーティションではありません: $partition"

	parent_name=$(lsblk -dnro PKNAME -- "$partition")
	[ -n "$parent_name" ] || sd_die "親デバイスを確認できません: $partition"
	parent_device=$(readlink -f -- "/dev/$parent_name")
	[ "$parent_device" = "$device" ] ||
		sd_die "$partition は $device のパーティションではありません"
}

sd_reject_critical_mounts()
{
	local device=$1
	local mount_point
	local mount_points

	mount_points=$(lsblk -nr -o MOUNTPOINTS -- "$device") ||
		sd_die "マウント状態を確認できません: $device"

	while IFS= read -r mount_point; do
		case "$mount_point" in
		/ | /boot | /boot/efi | /home | /usr | /var)
			sd_die "$device は重要なファイルシステム $mount_point を含むため使用できません"
			;;
		esac
	done <<<"$mount_points"
}

sd_require_label()
{
	local partition=$1
	local expected_label=$2
	local actual_label

	actual_label=$(lsblk -dnro LABEL -- "$partition")
	[ "${actual_label,,}" = "${expected_label,,}" ] ||
		sd_die "$partition のラベルが '$expected_label' ではありません（現在: '${actual_label:-なし}'）"
}

sd_confirm_device()
{
	local device=$1
	local action=$2
	local answer

	printf '\n対象デバイス:\n'
	lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS,MODEL -- "$device"
	printf '\n実行内容: %s\n' "$action"
	printf '続行するには対象デバイス名「%s」を入力してください: ' "$device"
	IFS= read -r answer || sd_die "確認を読み取れませんでした"
	[ "$answer" = "$device" ] || sd_die "確認が一致しないため中止しました"
}

sd_unmount_partition()
{
	local partition=$1
	local mount_points=()
	local mount_output
	local index

	mount_output=$(lsblk -nr -o MOUNTPOINTS -- "$partition") ||
		sd_die "マウント状態を確認できません: $partition"
	mapfile -t mount_points <<<"$mount_output"
	for ((index = ${#mount_points[@]} - 1; index >= 0; index--)); do
		[ -n "${mount_points[index]}" ] || continue
		printf 'アンマウント: %s\n' "${mount_points[index]}"
		umount -- "${mount_points[index]}"
	done
}

sd_require_unmounted()
{
	local partition=$1
	local mount_point
	local mount_points

	mount_points=$(lsblk -nr -o MOUNTPOINTS -- "$partition") ||
		sd_die "マウント状態を確認できません: $partition"
	while IFS= read -r mount_point; do
		[ -z "$mount_point" ] || sd_die "$partition はまだ $mount_point にマウントされています"
	done <<<"$mount_points"
}

sd_register_cleanup_dir()
{
	SD_CLEANUP_DIRS+=("$1")
}

sd_mount_partition()
{
	local partition=$1
	local mount_point=$2

	mount -- "$partition" "$mount_point"
	SD_CLEANUP_MOUNTS+=("$mount_point")
}

sd_assert_mount_source()
{
	local partition=$1
	local mount_point=$2
	local mounted_source

	mountpoint -q -- "$mount_point" || sd_die "マウントされていません: $mount_point"
	mounted_source=$(findmnt -nro SOURCE --target "$mount_point")
	mounted_source=$(readlink -f -- "$mounted_source")
	[ "$mounted_source" = "$partition" ] ||
		sd_die "$mount_point のマウント元が想定と異なります: $mounted_source"
}

sd_cleanup_resources()
{
	local index
	local result=0

	for ((index = ${#SD_CLEANUP_MOUNTS[@]} - 1; index >= 0; index--)); do
		if mountpoint -q -- "${SD_CLEANUP_MOUNTS[index]}"; then
			if ! umount -- "${SD_CLEANUP_MOUNTS[index]}"; then
				printf '警告: アンマウントできません: %s\n' "${SD_CLEANUP_MOUNTS[index]}" >&2
				result=1
			fi
		fi
	done

	for ((index = ${#SD_CLEANUP_DIRS[@]} - 1; index >= 0; index--)); do
		rmdir -- "${SD_CLEANUP_DIRS[index]}" 2>/dev/null || true
	done

	return "$result"
}

sd_install_cleanup_trap()
{
	trap 'SD_EXIT_STATUS=$?; trap - EXIT; sd_cleanup_resources || SD_EXIT_STATUS=1; exit "$SD_EXIT_STATUS"' EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
}

sd_finish_cleanup()
{
	sd_cleanup_resources
	trap - EXIT HUP INT TERM
}
