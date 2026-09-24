# 0009: host 側の USB モード切り替えに fwup task を使う

## 状態

採用

## 背景

ADR 0007 と USB モード単純化の実装では、Linux PC に挿した microSD の active DTB を
`sd/set_usb_mode.sh` で置き換えていた。この helper は対象デバイスの確認、mount / unmount、
FAT 上のファイル更新、`sync` を独自に実装していた。

一方、通常の Nerves application は `.fw` を作成し、`mix burn` から `fwup.conf` の任意 task を
`--task` で適用できる。`fwup` 自体が removable media の検出・unmount と FAT filesystem の更新を
扱えるため、USB モード選択だけのために別の SD 操作 script を維持する必要はない。

## 決定

host 側の USB モード選択は `fwup.conf` の次の task に統一する。

- `usb_host`: HOST 用 DTB を active `imx28-pwsh6.dtb` に書く
- `usb_ncm`: NCM 用 DTB を active `imx28-pwsh6.dtb` に書く

application directory からは通常の Nerves task として実行する。

```sh
mix burn --device /dev/sdX --task usb_host
mix burn --device /dev/sdX --task usb_ncm
```

これらは boot partition 上の active DTB だけを更新し、rootfs、firmware metadata、HOST / NCM の
参照 DTB は変更しない。fresh `mix burn` の `complete` task は引き続き HOST を既定にする。

PW-SH6 起動後の切り替えは引き続き System の `brain-usb-mode` を使い、KIOSK はその薄い UI とする。
`sd/set_usb_mode.sh` と互換 wrapper の `sd/use_usb_ncm.sh` は削除する。

ADR 0007 の「Linux PC から `sd/set_usb_mode.sh` で切り替える」という部分は、この ADR で置き換える。
`sd/populate_sd.sh` / `sd/deploy_release.sh` は別用途の legacy/recovery path として残す。

## 理由

- application 開発者の操作を `mix firmware` / `mix burn` / `mix burn --task ...` に揃えられる。
- removable media の検出・unmount・FAT 更新を `fwup` に任せ、独自 script の責務を減らせる。
- USB モードの payload は firmware に含まれる System 管理の DTB になり、host 側だけ別実装になることを防げる。
- on-device helper は boot partition の参照 DTB を使うため、既存の KIOSK 操作と責務分担は変わらない。

## 影響

- host 側で USB モードを変える前に、対象 application の `.fw` が `mix firmware` で生成済みである必要がある。
- `usb_host` / `usb_ncm` は既存の Brain boot partition を前提とし、参照 DTB がない media では失敗する。
  その場合は先に `mix burn` の `complete` task で firmware を書き込む。
- `sd/` は「すべての SD 操作を置く場所」ではなく、標準 Nerves workflow で置き換えていない
  legacy/recovery 用 script を置くディレクトリになる。

## 再評価条件

- USB role を Device Tree の差し替えではなく runtime で安全に変更できるようになった場合。
- boot partition の構成を変更し、active / reference DTB というモデル自体を廃止する場合。
- `mix upload` / A/B update 導入時に USB role selection も remote update policy に統合する場合。
