# nerves_system_brain

<img width="500" src="https://github.com/user-attachments/assets/79d09845-98a6-45fc-9da7-69e0bbc3db88" />

SHARP Brain 電子辞書 **PW-SH6**（NXP i.MX283 / ARMv5TEJ soft-float / 128MiB /
LCD 854×480）向けのカスタム Nerves システム。

> **免責**: 本リポジトリは**開発途中の試行錯誤の記録**であり、記載の手順・設定・調査結論は作者の環境
> (特定の個体・周辺機器・時点)での実測です。**動作を保証するものではありません。** 電子辞書の改造は
> 自己責任で行ってください(本体 eMMC には触らず microSD 起動のみで作業しています)。

動作例として `examples/hello_kiosk/` に `hello_kiosk_brain` を同梱する。

設計の全体像と「標準 Nerves に寄せる部分 / Brain 固有として残す部分」の考え方は
[アーキテクチャ概要](docs/README.md) を参照。

初めて実機で動かす場合は [初回セットアップガイド](docs/getting-started.md) を参照。

## 方針

- `nerves_system_br`（v1.34.3 / Buildroot 2026.05.2）を基盤にしつつ、通常の Nerves System
  dependency として `MIX_TARGET=brain` から参照できる形へ段階移行
- **カーネル・U-Boot・DTB はビルドせず**、[brain-hackers](https://github.com/brain-hackers)
  の成果物（buildbrain 2026-03-25 リリース）を流用
- ツールチェーンは Bootlin `armv5-eabi--glibc--stable`（soft-float）
- rootfs は **ext4**（このカーネルは squashfs 非対応）
- OTP 29 を armv5 でクロスビルド

## 構成

| パス                                            | 内容                                                                              |
| ----------------------------------------------- | --------------------------------------------------------------------------------- |
| `nerves_defconfig`                              | Buildroot 設定（arm926t / Bootlin armv5 / ext4 / カーネル非ビルド）               |
| `mix.exs`                                       | `nerves_system_brain` を `type: :system` として定義する System package metadata   |
| `toolchain/`                                    | `o/host` を再利用・artifact 化する `nerves_toolchain_brain`                       |
| `fwup.conf`                                     | 既存 FAT p1 + ext4 p2 レイアウト向けの PoC firmware 定義                         |
| `scripts/rel2fw.sh`                             | Nerves release から ext4 rootfs 入り `.fw` を生成する PoC script                 |
| `rootfs_overlay/etc/erlinit.config`             | PW-SH6 の bring-up / USB NCM 開発用設定（[詳細](docs/erlinit.md)）                |
| `rootfs_overlay/usr/bin/enable_ethernet_gadget` | configfs で NCM ガジェットを構成（`brain-config` 相当を移植）                     |
| `busybox.fragment`                              | USB NCM setup に必要な BusyBox `ln` / `tr` applet を追加                                 |
| `boot/imx28-pwsh6-peripheral.{dts,dtb}`           | USB NCM 用 Device Tree（[HOST / NCM の切り替え](sd/README.md)）                 |
| `sd/*.sh`                                       | SD の作成・配備スクリプト                                                         |
| `sd/deploy_release.sh`                          | 互換性のある Elixir release を `/srv/erlang` へ配置                               |
| `docs/release-deployment.md`                    | release の要件と System / application の責務分担                                  |
| `examples/hello_kiosk/`                         | PW-SH6 で動作確認済みの Elixir KIOSK 動作例                                       |
| `docs/`                                         | アーキテクチャ概要と ADR（設計判断）                                              |

## ビルド

```sh
# リポジトリの親ディレクトリに nerves_system_br v1.34.3 を取得
git clone --branch v1.34.3 --depth 1 \
  https://github.com/nerves-project/nerves_system_br.git ../nerves_system_br

# Buildroot を初期化してビルド
../nerves_system_br/create-build.sh nerves_defconfig o
make -C o           # OTP 29 の armv5 クロスビルドを含むため時間がかかる
```

USB NCM の configfs setup に必要な `ln` と `tr` は `busybox.fragment` で BusyBox に追加する。
`enable_ethernet_gadget` は標準の `ln -s` を使用し、独自 helper は必要としない。

### erlinit 立ち上げ用プロファイル

現在の `erlinit.config` は、PW-SH6 の実機 bring-up と USB NCM を使った開発を優先した
構成である。詳細な起動ログ、LCD コンソール、Erlang 終了後の調査用 shell などは
意図的に有効にしている bring-up 用設定であり、将来の運用構成の必須要件ではない。

USB NCM 関連の設定も開発用通信経路の一部であり、製品運用で常設することを意味しない。
各設定の役割と起動の流れは [`docs/erlinit.md`](docs/erlinit.md) を参照。

### 動作例（任意）

Nerves システム自体のビルドは `examples/` に依存しない。実機で動作確認する場合だけ、
`examples/hello_kiosk/` のリリースを構築する。`build_release.sh` は `o/staging` から
ARMv5 用 OTP アプリを取り込み、同じツールチェーンで `priv/kiosk_nif.so` も
クロスコンパイルする。

```sh
cd examples/hello_kiosk
./scripts/build_release.sh
```

別の `nerves_system_brain` を参照する場合は `NERVES_SYSTEM_BRAIN_DIR`、同じリポジトリで
別の Buildroot 出力を使う場合は `NERVES_BUILD_DIR` を指定できる。

```sh
NERVES_SYSTEM_BRAIN_DIR=/path/to/nerves_system_brain ./scripts/build_release.sh
NERVES_BUILD_DIR=/path/to/build-output ./scripts/build_release.sh
```

詳細は [`examples/hello_kiosk/README.md`](examples/hello_kiosk/README.md) を参照。

### 標準 Nerves 開発フロー PoC

`align-with-nerves-way` では、`nerves_system_brain` を通常の Nerves System dependency として
扱う PoC も進めている。既存の `o/` Buildroot 出力を再利用し、`examples/hello_kiosk/` から
`MIX_TARGET=brain` で参照する。

```sh
cd examples/hello_kiosk
export MIX_TARGET=brain

mise exec -- mix deps.get
mise exec -- mix firmware
mise exec -- mix burn
```

この repository 内の example は `../..` の `nerves_system_brain` を local path dependency として
参照する。System / toolchain package を公開した後は version dependency へ置き換え、application 側の
`MIX_TARGET=brain` / `mix firmware` / `mix burn` の流れは変えない方針とする。

既存の `o/` から、通常の Nerves System artifact も生成できる。

```sh
mise exec -- mix deps.get
scripts/fetch_boot_assets.sh
mise exec -- mix nerves.artifact nerves_toolchain_brain --path /tmp/brain-artifacts
mise exec -- mix nerves.artifact --path /tmp/brain-artifacts
```

生成物は `nerves_system_brain-portable-<version>-<checksum>.tar.gz` と host 別の
`nerves_toolchain_brain-<host>-<version>-<checksum>.tar.xz`。両 artifact を repository 外へ
展開し、`NERVES_SYSTEM` / `NERVES_TOOLCHAIN` をその path に指定した `hello_kiosk` の native
code cross compile と `mix firmware` まで確認済み。artifact を isolated download/cache directory
に置いた検証では、path override なしの Nerves resolver による両 artifact の取得と target compile
も確認できている。`fetch_boot_assets.sh` 実行後に作った System artifact は blank-SD boot bundle も
含む。GitHub release への公開と remote dependency としての取得は今後の作業になる。

この経路では `Nerves.Release.erts/0` を使い、release を `/srv/erlang` へ含めた ext4 rootfs を
`.fw` として生成する。`complete` task は FAT p1 と ext4 p2 を作成し、pinned buildbrain release から
取得・checksum 検証した boot loader / kernel / DTB と application release をまとめて配置する。
file target への firmware burn と生成 image の内容は host 上で確認済みで、blank SD からの実機 boot は
実機確認項目として残している。

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

# 3) アプリケーション release を配置する
sudo bash sd/deploy_release.sh /dev/sdX /path/to/release
```

`deploy_release.sh` はアプリケーション名に依存せず、完成済み release の内容を
`/srv/erlang` へ配置する。同梱の `hello_kiosk` を配置する場合は次のように指定する。

```sh
sudo bash sd/deploy_release.sh /dev/sdX \
  examples/hello_kiosk/_build/prod/rel/hello_kiosk_brain
```

release の要件と System / application の責務分担は
[`docs/release-deployment.md`](docs/release-deployment.md) を参照。

各スクリプトはパーティションとラベルを検査し、実行前に対象デバイスの情報を表示する。
続行には表示されたデバイス名の再入力が必要。自動マウント済みの対象パーティションは
処理前にアンマウントし、異常終了時にもスクリプトが作成したマウントを解除する。

`/dev/mmcblk0` など末尾が数字のデバイスでは、パーティション名の `p1`、`p2` を
自動的に補う。

### PW-SH6 の USB モード

USB0 のユーザー向けモードは **HOST** と **NCM** の2つに統一する。Device Tree ではそれぞれ
`dr_mode = "host"` / `dr_mode = "peripheral"` に対応し、同時には使用できない。

`mix burn` は HOST を既定にし、boot partition に HOST / NCM の参照 DTB を両方配置する。
Linux PC からは `sd/set_usb_mode.sh /dev/sdX {host|ncm}`、PW-SH6 上では
`brain-usb-mode {host|ncm}` で次回起動時のモードを選ぶ。KIOSK の USB 切替画面も同じ
`brain-usb-mode` を利用し、application 独自の DTB は持たない。

DTB の正本、切り替え方法、再生成方法は [`sd/README.md`](sd/README.md) を参照する。

## SSH / crng メモ

初期実装では独自 OTP `:ssh` daemon の crypto 初期化が UI を長時間ブロックしたため、遅延起動などの
PW-SH6 固有対策を入れていた。現在の標準化 branch では `NervesSSH` へ移行し、既知の PBKDF2 問題だけを
軽量 `pwdfun` override として残している。NervesSSH の初回 host-key generation を含む起動 cost は
次回実機で再確認する。過去の実測は worklog に残す。

## クレジット / ライセンス

本リポジトリで作成したプログラムは、原則として Apache License 2.0 の下で公開する。
文書とスクリーンショットは主に CC-BY-4.0、著作物性の低い設定・管理用ファイルは
CC0-1.0 として整理している。ファイル単位の著作権・ライセンス情報は
[`REUSE.toml`](REUSE.toml) と [`LICENSES/`](LICENSES/) を参照。

カーネル・U-Boot・配布イメージは
[brain-hackers](https://github.com/brain-hackers) プロジェクトの成果物（本リポジトリには
再配布用バイナリを含めない）。`boot/` の Device Tree ソースと生成済み DTB は
[brain-hackers/linux-brain](https://github.com/brain-hackers/linux-brain) 由来で、
元の GPL-2.0-or-later の扱いを保持している。

Nerves システムのビルド基盤は [nerves-project](https://github.com/nerves-project)。
`examples/hello_kiosk/` の LovyanGFX `MovingIcons` 由来アイコンデータは、
[LovyanGFX](https://github.com/lovyan03/LovyanGFX) の BSD-2-Clause 系ライセンスに
基づいて追跡している。詳細なクレジットは [`NOTICE`](NOTICE) を参照。
