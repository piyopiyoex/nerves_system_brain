#!/usr/bin/env bash
# CI とローカルで共通の軽量検証を実行する。
set -euo pipefail

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

die()
{
	printf 'エラー: %s\n' "$*" >&2
	exit 1
}

for command_name in bash sh cc cmp dtc git grep mktemp reuse; do
	command -v "$command_name" >/dev/null 2>&1 || die "必要なコマンドがありません: $command_name"
done

WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT HUP INT TERM

printf 'シェルスクリプトの構文を確認します。\n'
mapfile -t shell_files < <(git grep -Il '^#!.*sh$' --)
[ "${#shell_files[@]}" -gt 0 ] || die "検証対象のシェルスクリプトがありません"
for shell_file in "${shell_files[@]}"; do
	IFS= read -r shebang < "$shell_file"
	case "$shebang" in
		*bash) bash -n "$shell_file" ;;
		*) sh -n "$shell_file" ;;
	esac
done

printf 'lns をビルドします。\n'
lns_source=
for candidate in package/lns/lns.c src/lns.c; do
	if [ -f "$candidate" ]; then
		lns_source=$candidate
		break
	fi
done
[ -n "$lns_source" ] || die "lns のソースが見つかりません"
cc -Wall -Wextra -Werror -Os -static "$lns_source" -o "$WORK_DIR/lns"
"$WORK_DIR/lns" target "$WORK_DIR/link"
[ -L "$WORK_DIR/link" ] || die "lns の動作確認に失敗しました"

compile_dts()
{
	source_file=$1
	committed_dtb=$2
	generated_dtb="$WORK_DIR/$(basename -- "$committed_dtb")"

	dtc -q -I dts -O dtb -o "$generated_dtb" "$source_file"
	cmp -s "$generated_dtb" "$committed_dtb" ||
		die "$committed_dtb が $source_file から生成した内容と一致しません"
}

printf 'DTS のコンパイル結果を確認します。\n'
compile_dts sd/pwsh6.dts sd/imx28-pwsh6-peripheral.dtb
compile_dts sd/pwsh6-buzzer.dts sd/imx28-pwsh6-buzzer.dtb

printf '基本設定を確認します。\n'
[[ $(< VERSION) =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION が x.y.z 形式ではありません"
for required_config in \
	BR2_arm=y \
	BR2_arm926t=y \
	BR2_TOOLCHAIN_EXTERNAL_BOOTLIN_ARMV5_EABI_GLIBC_STABLE=y \
	BR2_TARGET_ROOTFS_EXT2_4=y; do
	grep -qx "$required_config" nerves_defconfig || die "nerves_defconfig に必要な設定がありません: $required_config"
done
grep -qx -- '-r /srv/erlang' rootfs_overlay/etc/erlinit.config ||
	die "erlinit.config の release 配置先が /srv/erlang ではありません"

printf 'ライセンス情報を確認します。\n'
reuse lint

printf 'すべての検証に成功しました。\n'
