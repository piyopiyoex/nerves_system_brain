# PW-SH6 の Device Tree

PW-SH6 の USB0 は、用途に応じて host / peripheral のどちらかを選択する。
両方を同時には使用できないため、このリポジトリでは特定の DTB を暗黙の標準として
SD カードへ上書きしない。

## 用途別の構成

| 構成 | Device Tree | 主な用途 |
|---|---|---|
| host | buildbrain の `imx28-pwsh6.dtb` | 有線 LAN、USB Audio、USB 接続の WiFi / BLE など |
| peripheral | `imx28-pwsh6-peripheral.dtb` | USB NCM による開発用通信 |

host 構成は brain-hackers/linux-brain の `arch/arm/boot/dts/imx28-pwsh6.dts` を正とし、
buildbrain 2026-03-25 リリースの PW-SH6 用 DTB をそのまま利用する。本リポジトリでは
同じ内容の host DTB / DTS を複製して管理しない。

peripheral 構成は buildbrain の PW-SH6 Device Tree を基に、USB0 の
`dr_mode = "host"` を `dr_mode = "peripheral"` に変更した PW-SH6 固有の派生である。
DTS を正として `imx28-pwsh6-peripheral.dts` を管理し、生成済み DTB を
`imx28-pwsh6-peripheral.dtb` として併せて保持する。

USB NCM は peripheral 構成を前提とする。host 構成を選択した場合、現在の USB NCM
ガジェットは利用できない。また、host 構成を選ぶこと自体は、有線 LAN、USB Audio、
WiFi / BLE の userspace 設定まで自動的に行うものではない。

## peripheral DTB の再生成

`dtc` が `PATH` にある環境で次を実行する。

```sh
dtc -q -I dts -O dtb \
  -o sd/imx28-pwsh6-peripheral.dtb \
  sd/imx28-pwsh6-peripheral.dts
```

`./scripts/check.sh` は DTS から一時 DTB を生成し、コミット済みの
`imx28-pwsh6-peripheral.dtb` と Device Tree の内容が一致することを確認する。

DTS / DTB の内容を変更した場合は、PW-SH6 実機で起動と対象の USB 用途を再確認する。

## SD カードでの選択

U-Boot が読み込むファイル名は、ブートパーティション上の `imx28-pwsh6.dtb` である。
通常の Nerves 開発フローでは、`mix burn` の `complete` task が buildbrain 由来の **host 構成**の
`imx28-pwsh6.dtb` を配置する。legacy / recovery 用の `sd/populate_sd.sh` は DTB を選択・置換しない。

host 構成を使う場合は、そのまま起動すればよい。

USB NCM 用の peripheral 構成へ切り替える場合は、`mix burn` の後に次の helper を実行する。

```sh
sudo bash sd/use_usb_ncm.sh /dev/sdX
```

`mix burn` をやり直すと host 構成へ戻るため、USB NCM を使う場合は burn のたびにこの helper を
再実行する。helper は対象デバイスを確認したうえで boot partition を安全に mount し、DTB の置き換え、
`sync`、unmount まで行う。通常は手動で partition を mount する必要はない。

2026-09-22 に、この手順で blank SD から USB NCM、mDNS、NervesSSH/IEx まで実機確認した。

`mix burn` 直後に partition label を取得できず `現在: 'なし'` と表示された場合は、Linux 側への反映を
待ってから再試行する。

```sh
sudo udevadm settle
sudo partprobe /dev/sdX
sudo udevadm settle
sudo bash sd/use_usb_ncm.sh /dev/sdX
```

これは書き込み直後にだけ必要になる復旧手順であり、通常の操作には含めない。

手動で配置する場合は、ブートパーティションをマウントしたうえで次のように置き換える。
`<boot-mount>` はそのマウントポイントに置き換える。

```sh
sudo cp sd/imx28-pwsh6-peripheral.dtb <boot-mount>/imx28-pwsh6.dtb
sync
```

host 構成へ戻す最も簡単な方法は、通常どおり `mix burn` を実行し直すこと。firmware を
書き直さず DTB だけ戻す場合は、buildbrain 由来の PW-SH6 用 `imx28-pwsh6.dtb` を同じ場所へ復元する。

## buzzer variant について

過去には内蔵 buzzer の調査用として `buzzer` / `buzzer_cold` を有効にした DTB を
試していたが、発音は確認できず、後続の実機調査でも Device Tree の変更を有力な解決策として
扱う根拠は得られなかった。このため現在の用途別 variant には含めない。調査経緯は
`examples/hello_kiosk/docs/` の ADR と worklog に残している。
