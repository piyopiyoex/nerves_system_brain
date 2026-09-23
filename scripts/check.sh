#!/usr/bin/env bash
# Fast, host-only checks used by local development and CI.
set -euo pipefail

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

require_command()
{
    local command_name=$1

    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'error: required command not found: %s\n' "$command_name" >&2
        exit 1
    }
}

collect_shell_files()
{
    local file
    local first_line

    while IFS= read -r -d '' file; do
        [ -f "$file" ] || continue

        IFS= read -r first_line < "$file" || true
        case "$file" in
        *.sh) ;;
        *)
            case "$first_line" in
            '#!/bin/sh' | '#!/bin/bash' | '#!/usr/bin/env sh' | '#!/usr/bin/env bash') ;;
            *) continue ;;
            esac
            ;;
        esac
        printf '%s\0' "$file"
    done < <(git ls-files -z)
}

require_command git
require_command bash
require_command sh
require_command shellcheck
require_command elixir
require_command dtc
require_command cmp
require_command awk
require_command mktemp
require_command rm

mapfile -d '' -t shell_files < <(collect_shell_files)

printf '==> shell syntax\n'
for file in "${shell_files[@]}"; do
    IFS= read -r first_line < "$file" || true
    case "$first_line" in
    *bash*) bash -n "$file" ;;
    *) sh -n "$file" ;;
    esac
done

printf '==> shellcheck\n'
shellcheck --severity=warning -x "${shell_files[@]}"

printf '==> Markdown relative links\n'
elixir scripts/check_markdown_links.exs

printf '==> DTS / DTB consistency\n'
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

generated_dtb="$tmp_dir/pwsh6.dtb"
generated_dts="$tmp_dir/generated.dts"
tracked_dts="$tmp_dir/tracked.dts"

dtc -q -I dts -O dtb -o "$generated_dtb" boot/imx28-pwsh6-peripheral.dts
dtc -q -I dtb -O dts -o "$generated_dts" "$generated_dtb"
dtc -q -I dtb -O dts -o "$tracked_dts" boot/imx28-pwsh6-peripheral.dtb
if ! cmp -s "$generated_dts" "$tracked_dts"; then
    printf '%s\n' \
        'error: boot/imx28-pwsh6-peripheral.dtb is not generated from boot/imx28-pwsh6-peripheral.dts' \
        'regenerate it with:' \
        '  dtc -I dts -O dtb boot/imx28-pwsh6-peripheral.dts -o boot/imx28-pwsh6-peripheral.dtb' >&2
    exit 1
fi

printf '==> HOST / NCM DTB invariant\n'
if [ ! -s boot/imx28-pwsh6.dtb ]; then
    printf '%s\n' \
        'error: boot/imx28-pwsh6.dtb is missing' \
        'run scripts/fetch_boot_assets.sh first' >&2
    exit 1
fi

host_dts="$tmp_dir/host.dts"
host_normalized="$tmp_dir/host-normalized.dts"
ncm_normalized="$tmp_dir/ncm-normalized.dts"

dtc -q -I dtb -O dts -o "$host_dts" boot/imx28-pwsh6.dtb

normalize_usb0_dr_mode()
{
    local input=$1
    local expected=$2
    local output=$3

    awk -v expected="$expected" -v input_name="$input" '
        BEGIN {
            in_usb0 = 0
            matches = 0
        }

        /^[[:space:]]*usb@80080000[[:space:]]*\{/ {
            in_usb0 = 1
        }

        in_usb0 && /dr_mode[[:space:]]*=/ {
            expected_line = "dr_mode = \"" expected "\";"
            if (index($0, expected_line) == 0) {
                printf "error: usb@80080000 has unexpected dr_mode while checking %s\n", input_name > "/dev/stderr"
                exit 1
            }

            sub(/dr_mode = "[^"]+";/, "dr_mode = \"__USB0_MODE__\";")
            matches++
        }

        { print }

        in_usb0 && /^[[:space:]]*};[[:space:]]*$/ {
            in_usb0 = 0
        }

        END {
            if (matches != 1) {
                printf "error: expected exactly one usb@80080000 dr_mode in %s, found %d\n", input_name, matches > "/dev/stderr"
                exit 1
            }
        }
    ' "$input" > "$output"
}

normalize_usb0_dr_mode "$host_dts" host "$host_normalized"
normalize_usb0_dr_mode "$tracked_dts" peripheral "$ncm_normalized"

if ! cmp -s "$host_normalized" "$ncm_normalized"; then
    printf '%s\n' \
        'error: HOST and NCM DTBs differ outside usb@80080000 dr_mode' \
        'NCM must remain a derivative of boot/imx28-pwsh6.dtb with only USB0 dr_mode changed to peripheral' >&2
    exit 1
fi

printf 'All checks passed.\n'
