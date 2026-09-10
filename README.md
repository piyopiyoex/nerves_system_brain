# nerves_system_brain

SHARP Brain 電子辞書 **PW-SH6**（NXP i.MX283 / ARMv5TEJ soft-float / 128MiB /
LCD 854×480）向けのカスタム Nerves システム。

アプリ側は [hello_kiosk_brain](https://github.com/kurokouji/hello_kiosk_brain)。

## 方針

- `nerves_system_br`（v1.34.3 / Buildroot 2026.05.2）を standalone で使用
- **カーネル・U-Boot・DTB はビルドせず**、[brain-hackers](https://github.com/brain-hackers)
  の成果物（buildbrain 2026-03-25 リリース）を流用
- ツールチェーンは Bootlin `armv5-eabi--glibc--stable`（soft-float）
- rootfs は **ext4**（このカーネルは squashfs 非対応）
- OTP 29 を armv5 でクロスビルド

## 構成

| パス | 内容 |
|---|---|
| `nerves_defconfig` | Buildroot 設定（arm926t / Bootlin armv5 / ext4 / カーネル非ビルド） |
| `rootfs_overlay/etc/erlinit.config` | コンソール(tty1) + USB-NCM ガジェット自動起動 |
| `rootfs_overlay/etc/usb-ncm.conf` | USB NCM の機器識別情報と Brain 側 IP アドレス |
| `rootfs_overlay/usr/bin/enable_ethernet_gadget` | configfs で NCM ガジェットを構成（`brain-config` 相当を移植） |
| `src/lns.c` | `symlink(2)` を呼ぶ静的ヘルパー（Nerves busybox に `ln` が無いため） |
| `sd/imx28-pwsh6-peripheral.dtb` | **USB を device モード化した DTB**（後述）/ `pwsh6.dts` はその DTS |
| `sd/*.sh` | SD の作成・配備スクリプト |

### USB NCM の初期化

`enable_ethernet_gadget` は `erlinit` から起動される。設定済みの gadget は再利用し、
不完全または設定が異なる場合は一度解除して再構成する。途中で失敗した場合は可能な範囲で
構成を解除し、失敗した処理と関連する状態を `/root/gadget_diag.log` に保存する。

機器ごとに変更する値は `rootfs_overlay/etc/usb-ncm.conf` にまとめている。

| 設定 | 既定値 | 役割 | 複数台での扱い |
|---|---|---|---|
| `USB_NCM_SERIAL_NUMBER` | `0123456789` | ホストが USB 機器を識別するシリアル番号 | 機器ごとに変更 |
| `USB_NCM_DEVICE_MAC` | `8a:15:8b:44:3a:02` | Brain 側の NCM インターフェースの MAC アドレス | 機器ごとに変更 |
| `USB_NCM_HOST_MAC` | `8a:15:8b:44:3a:01` | ホスト側に作成される NCM インターフェースの MAC アドレス | 機器ごとに変更 |
| `USB_NCM_IP_ADDRESS` | `10.42.0.2/24` | Brain の `usb0` に設定する IP アドレスとプレフィックス長 | 機器ごとにサブネットを変更 |

USB の manufacturer、product、configuration と `MaxPower` は PW-SH6 共通の値として
初期化スクリプト内に固定し、機器ごとの設定対象にはしない。

1 台だけを接続する場合は既定値のまま利用できる。同じ開発機へ複数台を同時に接続する場合は、
各機器のシリアル番号と両方の MAC アドレスを重複しない値に変更する。MAC アドレスには
ローカル管理のユニキャストアドレスを使用し、Brain 側とホスト側に異なる値を割り当てる。

また、同一の `10.42.0.0/24` を複数の USB ネットワークインターフェースで使用するとホストの
経路が競合するため、機器ごとにサブネットも分ける。例えば 2 台目では
次のように設定し、ホスト側を同じサブネットの `10.42.1.1/24` に設定する。

```sh
USB_NCM_SERIAL_NUMBER=brain-pwsh6-02
USB_NCM_DEVICE_MAC=8a:15:8b:44:3a:12
USB_NCM_HOST_MAC=8a:15:8b:44:3a:11
USB_NCM_IP_ADDRESS=10.42.1.2/24
```

設定を変更するときはビルド前に `usb-ncm.conf` を編集し、rootfs の再作成と配備後に
Brain を再起動する。ホスト側のネットワーク設定はこのリポジトリの対象外である。

## ビルド

```sh
# nerves_system_br を取得し create-build.sh で初期化
git clone --depth 1 https://github.com/nerves-project/nerves_system_br.git
./nerves_system_br/create-build.sh nerves_defconfig o
cd o && make        # OTP 29 の armv5 クロスビルド含む（時間がかかる）
```

`src/lns.c` は Bootlin ツールチェーンで別途ビルドして `rootfs_overlay/usr/bin/lns` に置く:

```sh
arm-linux-gcc -Os -static -o rootfs_overlay/usr/bin/lns src/lns.c
```

## SD カードの作成

ベースは brain-hackers の配布イメージ（**このリポジトリには含めない**。
[buildbrain releases](https://github.com/brain-hackers/buildbrain/releases) から
`sdimage-*.zip` を入手）。

```sh
# 1) ベースイメージを dd で書き込み
# 2) sd/populate_sd.sh で p2 を Nerves rootfs + OTP に差し替え
# 3) sd/deploy_release.sh で hello_kiosk_brain リリースを配置
```

### 重要: USB デバイスモード化 DTB（`imx28-pwsh6-peripheral.dtb`）

配布イメージの `imx28-pwsh6.dtb` は `usb@80080000` の `dr_mode` が **`host`** で、
USB ガジェット（NCM）が動かない。**brain-config の「ガジェット有効化」の実体は、
この dr_mode を `peripheral` に書き換えること**。本リポジトリの
`sd/imx28-pwsh6-peripheral.dtb` はそのパッチ済み版。ブートパーティション(p1)の
`imx28-pwsh6.dtb` をこれに置き換える。

配布イメージのオリジナル DTB からパッチを当てる手順:

```sh
dtc -I dtb -O dts imx28-pwsh6.dtb -o pwsh6.dts
# pwsh6.dts の usb@80080000 内 dr_mode = "host" を "peripheral" に
dtc -I dts -O dtb pwsh6.dts -o imx28-pwsh6-peripheral.dtb
```

## 既知の未解決課題

実機の `:ssh` デーモンは、ARMv5 の crng 初期化がエントロピー枯渇で完了せず
`:crypto.strong_rand_bytes` がブロックするため起動が不安定。詳細は
hello_kiosk_brain 側の `docs/20260903_SSH起動不能_セカンドオピニオン質問書.md` 参照。

## クレジット / ライセンス

カーネル・U-Boot・DTB・配布イメージは
[brain-hackers](https://github.com/brain-hackers) プロジェクトの成果物（本リポジトリには
再配布用バイナリを含めない）。Nerves システムのビルド基盤は
[nerves-project](https://github.com/nerves-project)。
