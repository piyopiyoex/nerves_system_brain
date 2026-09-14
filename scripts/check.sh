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
require_command python3
require_command dtc
require_command cmp
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
python3 scripts/check_markdown_links.py

printf '==> DTS / DTB consistency\n'
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

generated_dtb="$tmp_dir/pwsh6.dtb"
generated_dts="$tmp_dir/generated.dts"
tracked_dts="$tmp_dir/tracked.dts"

dtc -q -I dts -O dtb -o "$generated_dtb" sd/pwsh6.dts
dtc -q -I dtb -O dts -o "$generated_dts" "$generated_dtb"
dtc -q -I dtb -O dts -o "$tracked_dts" sd/imx28-pwsh6-peripheral.dtb
if ! cmp -s "$generated_dts" "$tracked_dts"; then
    printf '%s\n' \
        'error: sd/imx28-pwsh6-peripheral.dtb is not generated from sd/pwsh6.dts' \
        'regenerate it with:' \
        '  dtc -I dts -O dtb sd/pwsh6.dts -o sd/imx28-pwsh6-peripheral.dtb' >&2
    exit 1
fi

printf 'All checks passed.\n'
