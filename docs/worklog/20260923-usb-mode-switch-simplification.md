# 2026-09-23 USB モード切り替えの単純化

## 背景

USB NCM の実機検証後、PW-SH6 の USB0 を HOST / NCM で切り替える経路を見直した。
当時は次の3経路があり、参照する DTB も一致していなかった。

```text
mix burn
  -> System の host DTB

sd/use_usb_ncm.sh
  -> sd/ の peripheral DTB

KIOSK の「USB」切り替え
  -> examples/hello_kiosk/priv/dtb/ の独自 host / peripheral DTB
```

KIOSK 側の DTB は過去の buzzer 調査時の variant を基にしており、現在の System が使う DTB と
別管理になっていた。USB role 自体は Device Tree の `dr_mode` で決まり、切り替えには再起動が必要なので、
複数の DTB コピーと複数の書き換え実装を維持する理由はない。

## 方針

ユーザー向け USB モードを **HOST** と **NCM** の2つに統一する。

```text
HOST -> dr_mode = "host"
NCM  -> dr_mode = "peripheral"
```

`peripheral` は Device Tree 上の実装名としてだけ使い、通常の操作・UI・文書では NCM と呼ぶ。

System が USB モード用 DTB と切り替え処理を所有し、application は System helper を呼ぶだけにする。

## 実装

### boot partition に2つの参照 DTB を置く

`mix burn` の `complete` task は p1 に次を配置する。

```text
imx28-pwsh6.dtb             # active。U-Boot が読む
imx28-pwsh6-host.dtb        # HOST reference
imx28-pwsh6-peripheral.dtb  # NCM reference
```

fresh burn は HOST reference と同じ内容を active DTB に書くので、既定モードは HOST になる。
モード切り替えは active DTB をどちらかの reference で置き換えるだけで、rootfs や firmware metadata は変更しない。

### on-device helper を System に置く

`rootfs_overlay/usr/bin/brain-usb-mode` を追加した。

```sh
brain-usb-mode status
brain-usb-mode host
brain-usb-mode ncm
```

`status` は `/proc/device-tree/.../dr_mode` から現在起動中のモードを返す。
`host` / `ncm` は次回起動用 DTB を変更するだけで、自動 reboot は行わない。

### Linux PC 側の helper を対称にする

片方向だった `sd/use_usb_ncm.sh` の代わりに、次を標準手順にする。

```sh
sudo bash sd/set_usb_mode.sh /dev/sdX host
sudo bash sd/set_usb_mode.sh /dev/sdX ncm
```

`use_usb_ncm.sh` は既存手順との互換用 wrapper として残す。

### KIOSK を薄い frontend にする

`HelloKioskBrain.UsbMode` から次を削除した。

- application 内の DTB lookup
- boot partition の mount / unmount
- DTB の直接 copy / verify
- sysfs を組み合わせた USB role 推測

現在モードは Device Tree の `dr_mode` から読み、切り替えは `brain-usb-mode` に委譲する。
KIOSK の「リブート実行」は helper 成功後に reboot を行うだけになる。

`examples/hello_kiosk/priv/dtb/` の独自 DTB は削除した。

### 旧 SD patch helper を削除する

現在の firmware は `erlinit.config` と `enable_ethernet_gadget` を System の rootfs として生成するため、
既存 SD の p2 を個別に書き換える `sd/update_erlinit.sh` / `sd/update_gadget_v2.sh` は削除した。
特に `update_erlinit.sh` は `enable_ethernet_gadget` を単独の `--pre-run-exec` として追加する旧方式であり、
`prepare_brain_hardware` に集約した現在の起動経路とは両立しない。

また `scripts/check.sh` では、NCM DTB が HOST DTB から USB0 の `dr_mode` だけを変更した派生であることを
host-only check として検査する。

## 期待する確認

次の4ケースを同じ firmware で確認する。

1. fresh `mix burn` -> HOST で起動する
2. KIOSK から HOST -> NCM に切り替えて再起動できる
3. KIOSK から NCM -> HOST に切り替えて再起動できる
4. Linux PC から `sd/set_usb_mode.sh` で HOST / NCM の両方向を切り替えられる

各 boot で `brain-usb-mode status`、`VintageNet.info()`、`nerves.local`、NervesSSH/IEx を確認する。
Ethernet の実機検証はこの切り替え経路を確認した後に行う。
