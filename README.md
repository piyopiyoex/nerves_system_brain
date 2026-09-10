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
| `rootfs_overlay/usr/bin/enable_ethernet_gadget` | configfs で NCM ガジェットを構成（`brain-config` 相当を移植） |
| `package/lns/` | `symlink(2)` を呼ぶ静的ヘルパーの Buildroot package（BusyBox に `ln` が無いため） |
| `sd/imx28-pwsh6-peripheral.dtb` | **USB を device モード化した DTB**（後述）/ `pwsh6.dts` はその DTS |
| `sd/*.sh` | SD の作成・配備スクリプト |
| `docs/adr/` | 今後も参照する必要がある設計判断の記録 |

## ビルド

```sh
# リポジトリの親ディレクトリに nerves_system_br v1.34.3 を取得
git clone --branch v1.34.3 --depth 1 \
  https://github.com/nerves-project/nerves_system_br.git ../nerves_system_br

# Buildroot を初期化してビルド
../nerves_system_br/create-build.sh nerves_defconfig o
make -C o           # OTP 29 の armv5 クロスビルドを含むため時間がかかる
```

USB NCM の構成に必要な `lns` は、`package/lns/` から対象用ツールチェーンで自動的に
ビルドされ、rootfs の `/usr/bin/lns` へ配置される。事前の手動ビルドは不要。

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
