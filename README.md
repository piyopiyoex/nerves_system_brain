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
| `src/lns.c` | `symlink(2)` を呼ぶ静的ヘルパー（Nerves busybox に `ln` が無いため） |
| `sd/imx28-pwsh6-peripheral.dtb` | **USB を device モード化した DTB**（後述）/ `pwsh6.dts` はその DTS |
| `sd/*.sh` | SD の作成・配備スクリプト |

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

SD カード用スクリプトは Linux 上で実行し、対象となるディスク全体のデバイス名を
必ず引数で指定する。パーティション（`/dev/sdX1` など）は指定できない。
`populate_sd.sh` は対象の第2パーティションを再初期化し、既存内容をすべて消去する。

```sh
# 接続した記憶装置を確認する
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS,MODEL

# 1) buildbrain のベースイメージを SD カードへ書き込む
# 2) p2 を Nerves rootfs + OTP に差し替える
sudo bash sd/populate_sd.sh /dev/sdX

# 既定の o/ 以外を使用する場合はビルド出力ディレクトリも指定する
sudo bash sd/populate_sd.sh /dev/sdX /path/to/build-output

# 3) hello_kiosk_brain の初回リリースを配置する
sudo bash sd/deploy_release.sh /dev/sdX \
  /path/to/hello_kiosk_brain/_build/prod/rel/hello_kiosk_brain
```

各スクリプトはパーティションとラベルを検査し、実行前に対象デバイスの情報を表示する。
続行には表示されたデバイス名の再入力が必要。自動マウント済みの対象パーティションは
処理前にアンマウントし、異常終了時にもスクリプトが作成したマウントを解除する。

`/dev/mmcblk0` など末尾が数字のデバイスでは、パーティション名の `p1`、`p2` を
自動的に補う。

USB NCM 関連のファイルだけを既存の SD カードへ反映する補助スクリプトも、同様に
対象デバイスを指定して実行する。

```sh
sudo bash sd/update_erlinit.sh /dev/sdX
sudo bash sd/update_gadget_v2.sh /dev/sdX
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
