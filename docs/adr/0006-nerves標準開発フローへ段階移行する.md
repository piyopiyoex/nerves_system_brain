# 0006: Nerves 標準開発フローへ段階移行する

## 状態

採用

## 背景

ADR 0005 では、PW-SH6 の実機で成立している boot path を優先し、
`nerves_system_br` を standalone に近い形で利用することを採用した。

この方針により、brain-hackers 由来の U-Boot、Linux kernel、Device Tree、SD カード構成、
ext4 rootfs、実機で確認済みの起動手順を維持したまま、Nerves 互換 rootfs と OTP を
成立させることができた。

一方で、アプリケーション開発では Buildroot output、target OTP、ERTS headers、cross
compiler を個別に参照する必要があり、一般的な Nerves application の体験から離れている。
ADR 0005 の再評価条件である「他の Nerves アプリから通常の System dependency として
利用したくなった場合」に該当し始めている。

## 決定

`nerves_system_brain` を通常の Nerves System package として扱える方向へ段階的に移行する。

最初の段階では、PW-SH6 固有の boot / hardware / storage 構成は維持し、application
development interface だけを Nerves 標準へ近づける。

具体的には、以下を目標にする。

- `nerves_system_brain` を `type: :system` として定義する。
- `MIX_TARGET=brain` を導入する。
- `examples/hello_kiosk` から local path dependency として参照できるようにする。
- ARMv5 / Bootlin toolchain と sysroot / ERTS headers を Nerves environment から提供する。
- native code / NIF は `elixir_make` と Nerves の `CC` / `CXX` / `ERTS_INCLUDE_DIR` で
  build できる形へ寄せる。
- `fwup`、A/B slot、storage layout migration は別段階として扱う。

## 理由

- アプリケーション側から Buildroot output の内部構造を意識する範囲を減らせる。
- native build の target compiler / sysroot / ERTS headers を Nerves の責務に寄せられる。
- 現在動いている boot path を保持したまま、開発体験だけを先に改善できる。
- `mix compile` と `mix firmware` / `fwup` / A-B update は技術的に分けて検証できる。

## 影響

- root に `mix.exs` と Nerves package metadata が必要になる。
- local development では既存の `o/` Buildroot output を system artifact として再利用する。
- portable system artifact と Linux x86_64 toolchain artifact のローカル生成、および両方を
  repository 外へ展開した path からの native code compile / firmware 生成は確認済み。
  release / distribution 用には両 artifact の publish 手順を整備する必要がある。
- `examples/hello_kiosk` は target-aware な Nerves application になる。
- standalone build / deployment scripts は当面維持し、移行中の known-good path とする。
- ローカル System build は project-local な `mix brain.system.build` alias から行う。alias は pin 済みの
  `nerves_system_br` dependency を取得し、build 手順を再実装せず `create-build.sh` と `make` を順に
  呼び出して `o/` を生成する。
- 2026-09-21 時点で `examples/hello_kiosk` の `MIX_TARGET=brain mix firmware` から生成した
  firmware が PW-SH6 実機で boot し、KIOSK 表示、HOST-mode network、SSH/IEx 接続まで確認できた。
- `mix firmware` の `complete` task は fixed buildbrain boot bundle を FAT p1 へ書き込む。blank
  SD の raw image 上で p1 の FAT contents と p2 の release を確認済み。実機での blank SD boot と
  A/B update は別段階の検証対象として残す。
- `--boot shoehorn` への切り替えは PW-SH6 実機で確認済みとし、PoC の標準 boot path として採用する。
  実機上の `:init.get_argument(:boot)` は `/srv/erlang/releases/0.1.0/shoehorn` を返し、
  KIOSK、HOST-mode network、SSH direct exec が動作した。

## 残す PW-SH6 固有部分

- brain-hackers 由来の U-Boot / kernel / Device Tree。
- FAT boot partition と ext4 rootfs partition からなる現在の SD カード構成。
- ARM926EJ-S / ARMv5TEJ / soft-float 前提。
- display / input / power / audio などの device 固有初期化。
- 実機で確認済みの manual deployment path。

## 再評価条件

- `MIX_TARGET=brain mix compile` が安定しない場合。
- Nerves tooling が ARMv5 / soft-float / glibc の組み合わせに未対応であることが判明した場合。
- `fwup` を導入しないと application development flow の標準化も成立しないことが判明した場合。
- local `o/` 再利用ではなく、公開 artifact 前提へ早期に切り替える必要が出た場合。
