# PW-SH6 の USB モード

PW-SH6 の USB0 は **HOST** と **NCM** のどちらか一方で使用する。
ユーザー向けの呼び方はこの2つに統一する。

| モード | Device Tree の `dr_mode` | 主な用途 |
|---|---|---|
| HOST | `host` | USB Ethernet、USB Audio、USB 接続の WiFi / BLE など |
| NCM | `peripheral` | Linux PC と USB 直結する開発用通信 |

`peripheral` は Device Tree 上の実装名であり、通常の操作や UI では **NCM** と呼ぶ。
HOST と NCM は同時には使用できず、切り替えは **DTB を選択して再起動するだけ**である。

## Device Tree の正本

HOST は buildbrain 2026-03-25 release の PW-SH6 用 DTB をそのまま利用する。

```text
boot/imx28-pwsh6.dtb
```

NCM は同じ Device Tree を基に USB0 の `dr_mode` だけを `peripheral` にした派生として管理する。

```text
boot/imx28-pwsh6-peripheral.dts
boot/imx28-pwsh6-peripheral.dtb
```

application 側には DTB のコピーを持たない。USB モードの資産と切り替え処理は System 側に置く。

## boot partition の構成

`mix burn` の `complete` task は p1 に次の DTB を配置する。

```text
imx28-pwsh6.dtb             # active: U-Boot が読む
imx28-pwsh6-host.dtb        # HOST 用の参照コピー
imx28-pwsh6-peripheral.dtb  # NCM 用の参照コピー
```

fresh burn では active DTB に HOST 用を配置する。したがって `mix burn` 直後の既定モードは HOST である。
モード切り替えは `imx28-pwsh6.dtb` を参照コピーのどちらかで置き換えるだけで、rootfs や firmware metadata は
書き換えない。

## Linux PC から切り替える

SD カードを Linux PC に接続している場合は、次の1つの script を使う。

```sh
sudo bash sd/set_usb_mode.sh /dev/sdX host
sudo bash sd/set_usb_mode.sh /dev/sdX ncm
```

script は対象デバイスと `boot` label を確認し、p1 の参照 DTB から active DTB を更新して `sync` / unmount まで行う。
`/dev/sdX` は実際の microSD デバイスに読み替える。

以前の `sd/use_usb_ncm.sh` は互換用 wrapper として残しており、次と同じ意味になる。

```sh
sudo bash sd/use_usb_ncm.sh /dev/sdX
# == sudo bash sd/set_usb_mode.sh /dev/sdX ncm
```

新しい手順や文書では `set_usb_mode.sh` を使う。

## PW-SH6 上で切り替える

System は `/usr/bin/brain-usb-mode` を提供する。

```sh
brain-usb-mode status
brain-usb-mode host
brain-usb-mode ncm
```

`status` は現在起動中の Device Tree の `dr_mode` を読み、`host` / `ncm` / `unknown` のいずれかを返す。
`host` / `ncm` は **次回起動用**の active DTB を書き換えるだけで、自動では再起動しない。

```sh
brain-usb-mode ncm
reboot
```

KIOSK の「USB」画面はこの command を呼び出し、成功後に再起動する。application 自身は boot partition の
mount や DTB のコピーを実装しない。

## NCM 用 DTB の再生成

`dtc` が `PATH` にある環境で次を実行する。

```sh
dtc -q -I dts -O dtb \
  -o boot/imx28-pwsh6-peripheral.dtb \
  boot/imx28-pwsh6-peripheral.dts
```

`./scripts/check.sh` は DTS から一時 DTB を生成し、コミット済みの
`boot/imx28-pwsh6-peripheral.dtb` と Device Tree の内容が一致することを確認する。さらに HOST / NCM の
DTB を逆コンパイルして比較し、USB0 (`usb@80080000`) の `dr_mode` 以外に差分がないことも検査する。
DTS / DTB を変更した場合は、PW-SH6 実機で HOST / NCM の両方を再確認する。

## `mix burn` 直後に label を取得できない場合

書き込み直後だけ、Linux 側への partition / filesystem 情報の反映が間に合わず、
`set_usb_mode.sh` が label を `なし` と判定することがある。その場合だけ次を実行して再試行する。

```sh
sudo udevadm settle
sudo partprobe /dev/sdX
sudo udevadm settle
sudo bash sd/set_usb_mode.sh /dev/sdX ncm
```

これは復旧手順であり、通常の操作には含めない。

## 過去の buzzer variant について

過去には内蔵 buzzer の調査用として `buzzer` / `buzzer_cold` を有効にした DTB を試していたが、現在の
USB モード切り替えには使用しない。KIOSK にも独自 DTB を保持せず、System が管理する HOST / NCM の2種類だけを使う。
調査経緯は `examples/hello_kiosk/docs/` の ADR と worklog に残している。
