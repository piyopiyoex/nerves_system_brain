# 初回セットアップ: PW-SH6 で hello_kiosk を動かす

このガイドでは、`nerves_system_brain` をビルドし、通常の Nerves application と同じ流れで
`examples/hello_kiosk` の firmware を作成して microSD に書き込み、SHARP Brain PW-SH6 を
起動するまでを説明する。

接続方法は次の2通りを想定する。

- **USB 直接接続**: Linux PC と PW-SH6 を microUSB ケーブルで接続し、USB-NCM を使う。
- **有線 LAN**: PW-SH6 を USB host 構成のまま使い、USB Ethernet adapter から LAN に接続する。

> **注意**: microSD への書き込みでは、指定したデバイスの内容を消去する。
> 書き込み先を必ず確認すること。本体 eMMC には書き込まない。

## 1. 用意するもの

共通:

- Linux PC (`sudo` が使える環境)
- SHARP Brain PW-SH6
- microSD カードとカードリーダー
- `git`
- [mise](https://mise.jdx.dev/) または asdf

USB 直接接続では、**データ通信対応**の microUSB ケーブルも用意する。

有線 LAN 接続では、USB host 用の powered USB hub、USB Ethernet adapter、LAN 環境を用意する。

## 2. System をビルドする

現在は System / toolchain artifact の公開前なので、最初にローカルで System をビルドする。
`mix brain.system.build` alias が pin 済みの `nerves_system_br` dependency の取得、
Buildroot の設定更新、System build をまとめて実行する。
Erlang / Elixir は `.tool-versions` に合わせ、mise / asdf など任意のバージョンマネージャーで
事前にインストールする。以下は通常の `mix` コマンドとして実行する。

```sh
git clone https://github.com/piyopiyoex/nerves_system_brain.git
cd nerves_system_brain

mix brain.system.build
```

初回は OTP 29 の ARMv5 クロスビルドを含むため時間がかかる。`nerves_defconfig` や System 側を
変更した後も同じ alias を実行すればよく、build 前に Buildroot 設定を再生成する。
`o/` を捨てた完全な rebuild が必要な場合だけ `--clean` を使用する。

```sh
mix brain.system.build --clean
```

System / toolchain artifact を確認するときは、Buildroot 完了後にリポジトリルートで実行できる。

```sh
scripts/fetch_boot_assets.sh
mix nerves.artifact nerves_toolchain_brain --path /tmp/brain-artifacts
mix nerves.artifact --path /tmp/brain-artifacts
```

この artifact 作成は通常の application 開発には不要で、System の配布形態を確認するときに使う。

## 3. hello_kiosk firmware を作る

```sh
cd examples/hello_kiosk
export MIX_TARGET=brain
mix deps.get
mix firmware
```

`hello_kiosk` は同じ repository にある `nerves_system_brain` を local System dependency として参照する。
System package を公開した後は、この dependency を version 指定へ置き換えるだけで、application 側の
`MIX_TARGET=brain` / `mix firmware` の流れは変えない方針とする。

firmware 作成時に blank SD boot に必要な boot assets がまだなければ、pinned buildbrain release から
自動取得して SHA-256 を検証する。詳細は [boot assets](../boot/README.md) を参照。

SSH は `NervesSSH` を使用する。build 時に `~/.ssh/id_{rsa,ecdsa,ed25519}.pub` が見つかれば
authorized key として取り込む。公開鍵がない場合も、PW-SH6 で実測済みの軽量 `pwdfun` fallback により
`user` / `brain` で接続できるようにしている。

## 4. microSD に firmware を書き込む

カードリーダーを接続し、microSD のデバイスを確認する。

```sh
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS,MODEL
```

対象が microSD であることを確認したら、通常の Nerves 開発フローと同じように firmware を書き込む。

```sh
mix burn
```

表示された候補から microSD を選ぶ。

`complete` task は blank SD に MBR、FAT boot partition、ext4 rootfs partition を作成し、boot loader、
kernel、Device Tree、application release をまとめて配置する。

`mix burn` は boot partition に HOST / NCM の参照 DTB を両方配置し、active な
`imx28-pwsh6.dtb` には HOST 用 DTB を入れる。したがって fresh burn の既定モードは **HOST** である。
USB-NCM で Linux PC と直接接続する場合だけ、次節の `fwup` task で **NCM** を選ぶ。

## 5. 接続方法を選ぶ

### USB 直接接続

USB-NCM を使う場合は、`mix burn` の後に同じ firmware の `usb_ncm` task を microSD に適用する。
application directory のまま実行できる。

```sh
mix burn --device /dev/sdX --task usb_ncm
```

`/dev/sdX` は実際の microSD のデバイス名に読み替える。この task は既存の Brain boot partition を
確認し、firmware に含まれる NCM DTB を active `imx28-pwsh6.dtb` に書く。partition table、rootfs、
firmware metadata は変更しない。

通常の USB 直接接続の流れは次のとおり。

```text
mix firmware
  -> mix burn
  -> mix burn --device /dev/sdX --task usb_ncm
  -> microSD を PW-SH6 に挿す
  -> USB ケーブルを接続して起動
  -> ssh user@nerves.local
```

### 有線 LAN

有線 LAN を使う場合は **HOST** を選ぶ。fresh burn 直後は HOST なので追加操作は不要である。
NCM から戻す場合は同じ firmware の `usb_host` task を適用する。

```sh
mix burn --device /dev/sdX --task usb_host
```

HOST / NCM の仕組みと、PW-SH6 起動後の切り替え方法は [PW-SH6 の USB モード](usb-mode.md) を参照する。

## 6. PW-SH6 を起動する

1. microSD を PW-SH6 に挿入する。
2. 接続方法に合わせてケーブルや周辺機器を接続する。
3. PW-SH6 を起動する。
4. LCD に KIOSK 画面が表示されることを確認する。

起動後に次回の USB モードを変える場合は、IEx / console から System helper を使える。

```sh
brain-usb-mode status
brain-usb-mode host   # または: brain-usb-mode ncm
reboot
```

KIOSK のホーム画面にある「USB」から HOST / NCM を選ぶ場合も、内部では同じ `brain-usb-mode` を使用する。

## 7. Linux PC から接続する

### USB 直接接続

peripheral DTB では System が NCM gadget を作り、`VintageNetDirect` が `usb0` の address と
Linux PC 側への DHCP を管理する。従来の `10.42.0.1/24` 手動設定は不要になる。

PW-SH6 の起動後、Linux PC に USB ネットワークインターフェースと address が追加されたことを確認する。

```sh
ip -br addr
ping nerves.local
ssh user@nerves.local
```

2026-09-22 の実機確認では、PW-SH6 の `usb0` に `172.31.172.181/30`、Linux PC 側に
`172.31.172.182/30` が割り当てられ、`nerves.local` で ping と SSH/IEx 接続を確認した。
この /30 subnet は `VintageNetDirect` が選ぶため、上記 address を固定値として設定しない。

`nerves.local` が名前解決できない環境では、KIOSK 画面または Linux PC のネットワーク状態から
PW-SH6 側の address を確認して直接指定する。

### 有線 LAN

host DTB では USB Ethernet adapter を `VintageNetEthernet` が管理し、LAN の DHCP server から
address を取得する。mDNS が利用できれば USB direct と同じ名前で接続できる。

```sh
ping nerves.local
ssh user@nerves.local
```

名前解決できない場合は KIOSK 画面や DHCP server 側で address を確認する。

`NervesSSH` が IEx / direct exec / SFTP を提供する。公開鍵が取り込まれていない場合は、
移行中の fallback として `user` / `brain` でも接続できる。正常なら対話 IEx が開く。

Elixir 式を1回だけ実行することもできる。

```sh
ssh user@nerves.local 'node()'
```

ファイル転送には SFTP を使用できる。

```sh
sftp user@nerves.local
```

## 8. うまく接続できない場合

USB 直接接続でネットワークインターフェースが現れない場合は、まず次を確認する。

- microUSB ケーブルがデータ通信対応か。
- current firmware を `mix firmware` で生成し、対象 SD に `mix burn --device /dev/sdX --task usb_ncm` を適用したか。
- ケーブルを一度抜き差しする。
- `brain-usb-mode status` が `ncm` を返すか。
- 現在の立ち上げ用 helper が出力する `/root/gadget_diag.log` を確認する。rootfs は writable ext4 なので、
  起動できない場合でも microSD の p2 を Linux PC で mount して読める。

`usb_host` / `usb_ncm` task が boot partition の参照 DTB 不在で失敗する場合は、その media が現在の
firmware layout になっていない。先に通常の `mix burn` (`complete` task) で firmware を書き込んでから
mode task を再実行する。

有線 LAN で接続できない場合は、USB Ethernet adapter が認識されていること、LAN 側の DHCP server が
利用できることを確認する。IEx/console が使える場合は `VintageNet.info()` で interface state を確認する。

USB 直接接続 / 有線 LAN のどちらでも `nerves.local` が解決できない場合は、まず IP address で疎通を確認する。

SSH が `Connection refused` になる場合は、起動直後または NervesSSH の初回ホスト鍵生成中の
可能性がある。少し待ってから再試行し、必要なら `VintageNet.info()` と NervesSSH の起動状態を確認する。

以前の SD カードと同じ hostname/address で ホスト鍵の警告が出る場合は、古い鍵を削除する。

```sh
ssh-keygen -R nerves.local
```

## 関連ドキュメント

- [nerves_system_brain](../README.md) - リポジトリ全体の概要
- [アーキテクチャ概要](README.md) - 設計方針と全体像
- [PW-SH6 の erlinit 立ち上げ設定](erlinit.md) - `erlinit` と起動処理
- [PW-SH6 の USB モード](usb-mode.md) - HOST / NCM の切り替え
- [hello_kiosk](../examples/hello_kiosk/README.md) - example application の詳細
