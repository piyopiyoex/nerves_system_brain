# 0010: legacy deployment path を廃止する

## 状態

採用

## 背景

PR #44 では application 開発を標準 Nerves workflow に寄せ、`mix firmware` で `.fw` を生成し、
`mix burn` で blank SD へ書き込む経路を PW-SH6 実機で確認した。HOST / NCM の切り替えも、
Linux PC 側は `fwup` task、PW-SH6 側は `brain-usb-mode` に統一できた。

一方、以前の bring-up で使用していた `sd/populate_sd.sh`、`sd/deploy_release.sh`、
`examples/hello_kiosk/scripts/build_release.sh` は、ERTS 非同梱 release を既存 rootfs に手動配備する
別経路を維持していた。標準 workflow が成立した後もこの経路を残すと、build / provisioning / recovery の
責務が二重化し、どちらを現在の正規手順とするかが曖昧になる。

## 決定

application の build / provisioning は次の経路に統一する。

```text
mix brain.system.build
        ↓
mix firmware
        ↓
mix burn
```

Linux PC から USB mode を変更する場合は、同じ firmware の `fwup` task を使う。

```sh
mix burn --device /dev/sdX --task usb_host
mix burn --device /dev/sdX --task usb_ncm
```

以下の legacy deployment path は廃止する。

- `sd/populate_sd.sh`
- `sd/deploy_release.sh`
- `sd/lib/sd_card.sh`
- `examples/hello_kiosk/scripts/build_release.sh`
- `docs/release-deployment.md`

USB mode の current documentation は `docs/usb-mode.md` に置く。
`scripts/rel2fw.sh` は legacy deployment helper ではなく、ext4 rootfs を使う現在の Nerves firmware
生成経路を成立させる System 固有 adapter なので維持する。

ADR 0007 の legacy/recovery SD script を残す判断、および ADR 0009 の
`sd/populate_sd.sh` / `sd/deploy_release.sh` を残す記述は、この ADR で置き換える。

## 理由

- application 開発者が覚える build / provisioning path を1つにできる。
- blank SD の作成と application release の配置を同じ `.fw` / `fwup` workflow で扱える。
- host 側 USB mode 切り替えも firmware task に統一し、独自 mount/copy script を不要にできる。
- 古い recovery path の保守・検証コストと、current documentation との不整合をなくせる。

## 影響

- 旧 script を使った手順は current workflow ではサポートしない。
- 過去の ADR / worklog に残る旧 script 名や手順は、当時の記録として書き換えない。
- recovery が必要な場合も、まず current System を build し、`mix firmware` / `mix burn` で SD を再作成する。
- A/B update や `mix upload` は引き続き別設計とする。

## 再評価条件

- `mix upload` / A/B update を導入し、provisioning と remote update の責務を再整理する場合。
- current `fwup` firmware では復旧できない実機障害が確認され、専用 recovery tool が必要になった場合。
