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

- `nerves_system_br`（v1.34.3 / Buildroot 2026.05.2）を基盤にし、通常の Nerves System
  dependency として `MIX_TARGET=brain` から参照する
- **カーネル・U-Boot・DTB はビルドせず**、[brain-hackers](https://github.com/brain-hackers)
  の成果物（buildbrain 2026-03-25 リリース）を流用
- ツールチェーンは Bootlin `armv5-eabi--glibc--stable`（soft-float）
- rootfs は **ext4**（このカーネルは squashfs 非対応）
- OTP 29 を armv5 でクロスビルド

## 構成

| パス                                            | 内容                                                                              |
| ----------------------------------------------- | --------------------------------------------------------------------------------- |
| `nerves_defconfig`                              | Buildroot 設定（arm926t / Bootlin armv5 / ext4 / カーネル非ビルド）               |
| `mix.exs`                                       | System package metadata とローカル System build 用 `brain.system.build` alias      |
| `toolchain/`                                    | `o/host` を再利用・artifact 化する `nerves_toolchain_brain`                       |
| `fwup.conf`                                     | FAT p1 + ext4 p2/p3(A/B) + p4(data) の firmware 定義、`mix upload`、HOST / NCM task |
| `scripts/rel2fw.sh`                             | Nerves release を ext4 rootfs に統合して `.fw` を生成する System 固有 adapter     |
| `rootfs_overlay/etc/erlinit.config`             | PW-SH6 の bring-up / USB NCM 開発用設定（[詳細](docs/erlinit.md)）                |
| `rootfs_overlay/usr/bin/enable_ethernet_gadget` | configfs で NCM ガジェットを構成（`brain-config` 相当を移植）                     |
| `busybox.fragment`                              | USB NCM / mode switch に必要な BusyBox `ln` / `tr` / `sync` applet を追加                 |
| `boot/imx28-pwsh6-peripheral.{dts,dtb}`        | USB NCM 用 Device Tree（[HOST / NCM の切り替え](docs/usb-mode.md)）              |
| `docs/usb-mode.md`                              | HOST / NCM の切り替え方と Device Tree の管理方針                                |
| `examples/hello_kiosk/`                         | PW-SH6 で動作確認済みの Elixir KIOSK 動作例                                       |
| `docs/`                                         | アーキテクチャ概要と ADR（設計判断）                                              |

## ビルド

ローカル System build は project-local な Mix alias から行う。alias は `mix.exs` で pin した
`nerves_system_br` dependency を使い、`create-build.sh` による Buildroot 設定更新と `make` を順に実行する。

Erlang / Elixir のバージョンは `.tool-versions` に合わせ、mise / asdf など任意の
バージョンマネージャーで準備する。System build alias は必要な Mix dependency も取得するため、
fresh clone からそのまま実行できる。

```sh
mix brain.system.build
```

既存の `o/` を捨てて完全に作り直す場合は `--clean` を付ける。

```sh
mix brain.system.build --clean
```

初回や clean build は OTP 29 の ARMv5 クロスビルドを含むため時間がかかる。
通常は `create-build.sh` や `make -C o` を直接実行する必要はない。

USB NCM の configfs setup に必要な `ln` と `tr`、USB mode 切り替えに必要な `sync` は `busybox.fragment` で BusyBox に追加する。
`enable_ethernet_gadget` は標準の `ln -s` を使用し、独自 helper は必要としない。

### erlinit 立ち上げ用プロファイル

現在の `erlinit.config` は、PW-SH6 の実機 bring-up と USB NCM を使った開発を優先した
構成である。詳細な起動ログ、LCD コンソール、Erlang 終了後の調査用 shell などは
意図的に有効にしている bring-up 用設定であり、将来の運用構成の必須要件ではない。

USB NCM 関連の設定も開発用通信経路の一部であり、製品運用で常設することを意味しない。
各設定の役割と起動の流れは [`docs/erlinit.md`](docs/erlinit.md) を参照。

### 動作例: hello_kiosk

Nerves システム自体のビルドは `examples/` に依存しない。実機で動作確認する場合は、
`examples/hello_kiosk/` を通常の Nerves application としてビルドする。

```sh
cd examples/hello_kiosk
export MIX_TARGET=brain

mix deps.get
mix firmware
mix burn
```

この repository 内の example は `../..` の `nerves_system_brain` を local path dependency として
参照する。System / toolchain package を公開した後は version dependency へ置き換えても、application 側の
`MIX_TARGET=brain` / `mix firmware` / `mix burn` / `mix upload` の流れを通常の Nerves application と同じ形で維持する。

この経路では `Nerves.Release.erts/0` を使い、release を `/srv/erlang` へ含めた ext4 rootfs を
`.fw` として生成する。`complete` task は FAT p1、ext4 p2(A) / p3(B)、persistent data 用の p4 を作成し、
pinned buildbrain release から取得・checksum 検証した boot loader / kernel / DTB と application release を
まとめて配置する。p4 は残り容量まで拡張され、初回起動時に `Nerves.Runtime` が ext4 として `/root` へ mount する。
fresh burn からの HOST boot、KIOSK 経由の HOST / NCM 切り替え、両モードの network 接続まで
PW-SH6 実機で確認済みである。

既存の `o/` から通常の Nerves System / toolchain artifact も生成できる。

```sh
mix deps.get
scripts/fetch_boot_assets.sh
mix nerves.artifact nerves_toolchain_brain --path /tmp/brain-artifacts
mix nerves.artifact --path /tmp/brain-artifacts
```

生成物は `nerves_system_brain-portable-<version>-<checksum>.tar.gz` と host 別の
`nerves_toolchain_brain-<host>-<version>-<checksum>.tar.xz`。local artifact の取得と target compile /
`mix firmware` は確認済みで、GitHub release への公開は別作業とする。

## SD カードと USB モード

通常の initial provisioning は application directory から `mix burn` を使う。brain-hackers の
base image を手動で先に書き込む必要はない。

```sh
cd examples/hello_kiosk
export MIX_TARGET=brain
mix firmware
mix burn
```

`complete` task は blank SD に MBR、FAT boot partition、ext4 rootfs A/B partition、persistent data partition を
作り、slot A と HOST を既定として配置する。

USB0 のユーザー向けモードは **HOST** と **NCM** の2つに統一する。Device Tree ではそれぞれ
`dr_mode = "host"` / `dr_mode = "peripheral"` に対応し、同時には使用できない。

Linux PC に挿した SD の次回起動 mode を変更する場合は、独自 mount script ではなく firmware の
`fwup` task を `mix burn --task` から適用する。

```sh
mix burn --device /dev/sdX --task usb_host
mix burn --device /dev/sdX --task usb_ncm
```

PW-SH6 上では `brain-usb-mode {host|ncm}` を使う。KIOSK の USB 切替画面も同じ helper を利用し、
application 独自の DTB や SD mount 処理は持たない。DTB の正本、切り替え方法、再生成方法は
[`docs/usb-mode.md`](docs/usb-mode.md) を参照する。

## firmware を更新する

A/B layout で一度 `mix burn` した後は、application firmware の更新に standard `mix upload` を使える。

```sh
cd examples/hello_kiosk
export MIX_TARGET=brain
mix firmware
mix upload nerves.local
```

起動中の rootfs が A(p2) なら B(p3)、B なら A へ書き込み、成功後に次回 boot slot を切り替えて再起動する。
`mix upload` は shared p1 の kernel / DTB / boot loader と p4 の persistent data を更新せず、HOST / NCM の
active DTB も維持する。p4 は `/root` に mount され、rootfs の `/data -> root` により NervesSSH host key なども
slot 切り替えをまたいで保持される。System-level boot asset を変更した場合は `mix burn` を使用する。fresh `mix burn` は p4 も
再作成するため、persistent data を保持したままの System update にはならない。automatic rollback は現段階では持たない。

2026-09-24 に PW-SH6 実機で A -> B -> A の往復、p4 mount、`/data` の継続、SSH host key の継続を確認した。
詳細と recovery 手順は [`docs/mix-upload.md`](docs/mix-upload.md)、検証記録は
[`docs/worklog/20260924-mix-upload-real-device-verification.md`](docs/worklog/20260924-mix-upload-real-device-verification.md) を参照する。

## SSH / crng メモ

初期実装では独自 OTP `:ssh` daemon の crypto 初期化が UI を長時間ブロックしたため、遅延起動などの
PW-SH6 固有対策を入れていた。現在は `NervesSSH` へ移行し、既知の PBKDF2 問題だけを
軽量 `pwdfun` override として残している。NervesSSH / IEx / SFTP 接続は実機確認済みである。
OTP 29 の persistent shell history はこの実機で interactive IEx の開始を止める現象を確認したため、
`hello_kiosk` では明示的に無効化している。過去の調査経緯は worklog に残す。

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
