#!/bin/bash
# 互換用 wrapper。新しい手順では set_usb_mode.sh DEVICE ncm を使用する。
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

usage()
{
    printf '使用方法: sudo bash %s DEVICE\n' "$0" >&2
    printf '例: sudo bash %s /dev/sdX\n' "$0" >&2
    exit 2
}

[ "$#" -eq 1 ] || usage
exec bash "$SCRIPT_DIR/set_usb_mode.sh" "$1" ncm
