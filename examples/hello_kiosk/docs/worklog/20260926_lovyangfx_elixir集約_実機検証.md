# lovyangfx_elixir 集約・実機検証

## 目的

`hello_kiosk` が直接所有していた LovyanGFX source、NIF、TSV command interpreter、
MovingIcons native implementation を `lovyangfx_elixir` に集約し、SHARP Brain PW-SH6 で
描画と lifecycle の parity を確認する。

## 構成

- `lovyangfx_elixir` commit: `cc2ec000b16641284b844345327076f556da6593`
- LovyanGFX: `1.2.29`
- framebuffer: 854x480、RGB565、stride 1708 bytes
- mode: `:buffered_rgb565`、`swap_bytes: true`
- `HelloKioskBrain.Native`: package public API への adapter
- `HelloKioskBrain.Draw`: 既存 API から LovyanGFX command tuple への変換

KIOSK の `Makefile` は `devmem` helper だけを build する。旧 `kiosk_nif.cpp`、
`kiosk_draw.hpp`、`icons.cpp` と KIOSK 側 icon data は削除した。

## build 結果

- package test: 35 tests、failure 0（hardware tags 4 件を除外）
- KIOSK host test: 6 tests、failure 0
- ARM926EJ-S / ARM EABI5 soft-float cross compile: 成功
- `lovyangfx_nif.so`: stripped、約 5.2 MiB
- production firmware build / standard `mix upload`: 成功

## PW-SH6 実機結果

- application と NIF が正常起動し、`LovyanGFX.width/0` / `height/0` は 854 / 480
- KIOSK home の日本語、配色、orientation を framebuffer screenshot で確認
- 図形、IPA 日本語 font、sprite、rotate / zoom を確認
- RGB565 framebuffer bytes:
  - 背景 `0x00182F`: `C5 00`
  - red: `00 F8`
  - green: `E0 07`
  - blue: `1F 00`
- MovingIcons start / stop / restart を複数回実行し、全て `:ok`
- 120 full-frame render: 5.563 秒、全て `:ok`
- 上記 render 中も 5 ms heartbeat process が 618 回実行され、scheduler 停止なし
- MovingIcons 連続描画: 143 秒、停止・thread join・KIOSK 復帰に成功
- soak 終了時の BEAM total memory 差: +352,912 bytes
- BEAM crash、NIF crash、framebuffer capture の破損は観測せず
- 物理 LCD を肉眼確認し、tearing / flicker の悪化やその他の異常なし

実機 probe で、正規化済み RGB565 integer を native 側が RGB888 として再変換する既存不具合を
発見した。native boundary で `lgfx::rgb565_t` を明示し、上記 framebuffer byte 値で修正を確認した。
