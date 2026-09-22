# 初回セットアップ: PW-SH6 で hello_kiosk を動かす

このガイドでは、`nerves_system_brain` をビルドし、通常の Nerves application と同じ流れで
`examples/hello_kiosk` の firmware を作成して microSD に書き込み、SHARP Brain PW-SH6 を
起動するまでを説明する。

接続方法は次の2通りを想定する。

- **USB 直接接続**: Linux PC と PW-SH6 を microUSB ケーブルで接続し、USB-NCM を使う。
- **Ethernet**: PW-SH6 を USB host 構成のまま使い、USB Ethernet adapter から LAN に接続する。

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

Ethernet 接続では、USB host 用の powered USB hub、USB Ethernet adapter、LAN 環境を用意する。

## 2. System をビルドする

現在は System / toolchain artifact の公開前なので、最初にローカルで System をビルドする。

```sh
git clone https://github.com/piyopiyoex/nerves_system_brain.git
cd nerves_system_brain

git clone --branch v1.34.3 --depth 1 \
  https://github.com/nerves-project/nerves_system_br.git ../nerves_system_br

../nerves_system_br/create-build.sh nerves_defconfig o
make -C o
```

初回は OTP 29 の ARMv5 クロスビルドを含むため時間がかかる。

System / toolchain artifact を確認するときは、Buildroot 完了後に repository root で実行できる。

```sh
mise trust
mise install
mise exec -- mix deps.get
scripts/fetch_boot_assets.sh
mise exec -- mix nerves.artifact nerves_toolchain_brain --path /tmp/brain-artifacts
mise exec -- mix nerves.artifact --path /tmp/brain-artifacts
```

この artifact 作成は通常の application 開発には不要で、System の配布形態を確認するときに使う。

## 3. hello_kiosk firmware を作る

```sh
cd examples/hello_kiosk
mise trust
mise install

export MIX_TARGET=brain
mise exec -- mix deps.get
mise exec -- mix firmware
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

対象が microSD であることを確認したら、通常の Nerves workflow と同じように firmware を書き込む。

```sh
mise exec -- mix burn
```

表示された候補から microSD を選ぶ。

`mix burn` の `complete` task は毎回 boot partition に host 用 `imx28-pwsh6.dtb` を配置する。
USB-NCM を使う場合は、burn のたびに次節の `sd/use_usb_ncm.sh` を再実行する。

`complete` task は blank SD に MBR、FAT boot partition、ext4 rootfs partition を作成し、boot loader、
kernel、Device Tree、application release をまとめて配置する。

## 5. 接続方法を選ぶ

### USB 直接接続

USB-NCM を使う場合だけ、microSD の Device Tree を peripheral 構成へ切り替える。
repository root に戻って実行する。

```sh
cd ../..
sudo bash sd/use_usb_ncm.sh /dev/sdX
```

`/dev/sdX` は実際の microSD のデバイス名に読み替える。
`erlinit.config` の手作業による切り替えは不要。

### Ethernet

Ethernet を使う場合は追加の SD 設定は不要。blank SD firmware に入る upstream の
`imx28-pwsh6.dtb` は USB host 構成なので、そのまま使用する。

host / peripheral の詳細は [PW-SH6 の Device Tree](../sd/README.md) を参照。

## 6. PW-SH6 を起動する

1. microSD を PW-SH6 に挿入する。
2. 接続方法に合わせてケーブルや周辺機器を接続する。
3. PW-SH6 を起動する。
4. LCD に KIOSK 画面が表示されることを確認する。

## 7. Linux PC から接続する

### USB 直接接続

peripheral DTB では System が NCM gadget を作り、`VintageNetDirect` が `usb0` の address と
Linux PC 側への DHCP を管理する。従来の `10.42.0.1/24` 手動設定は不要になる。

PW-SH6 の起動後、Linux PC に USB network interface と address が追加されたことを確認する。

```sh
ip -br addr
ping nerves.local
ssh user@nerves.local
```

2026-09-22 の実機確認では、PW-SH6 の `usb0` に `172.31.172.181/30`、Linux PC 側に
`172.31.172.182/30` が割り当てられ、`nerves.local` で ping と SSH/IEx 接続を確認した。
この /30 subnet は `VintageNetDirect` が選ぶため、上記 address を固定値として設定しない。

`nerves.local` が名前解決できない環境では、KIOSK 画面または Linux PC の network state から
PW-SH6 側の address を確認して直接指定する。

### Ethernet

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

USB 直接接続で network interface が現れない場合は、まず次を確認する。

- microUSB ケーブルがデータ通信対応か。
- 最新の `mix burn` 後に `sd/use_usb_ncm.sh /dev/sdX` を実行したか。
- ケーブルを一度抜き差しする。
- 現在の bring-up helper が出力する `/root/gadget_diag.log` を確認する。rootfs は writable ext4 なので、
  起動できない場合でも microSD の p2 を Linux PC で mount して読める。

Ethernet で接続できない場合は、USB Ethernet adapter が認識されていること、LAN 側の DHCP server が
利用できることを確認する。IEx/console が使える場合は `VintageNet.info()` で interface state を確認する。

USB direct / Ethernet のどちらでも `nerves.local` が解決できない場合は、まず IP address で疎通を確認する。

SSH が `Connection refused` になる場合は、起動直後または NervesSSH の初回 host-key generation 中の
可能性がある。少し待ってから再試行し、必要なら `VintageNet.info()` と NervesSSH の起動状態を確認する。

以前の SD カードと同じ hostname/address で host key warning が出る場合は、古い key を削除する。

```sh
ssh-keygen -R nerves.local
```

## 関連ドキュメント

- [nerves_system_brain](../README.md) - リポジトリ全体の概要
- [アーキテクチャ概要](README.md) - 設計方針と全体像
- [PW-SH6 の erlinit bring-up profile](erlinit.md) - `erlinit` と起動処理
- [PW-SH6 の Device Tree](../sd/README.md) - host / peripheral の選択
- [アプリケーション release の作成と配置](release-deployment.md) - application release の要件と配置
- [hello_kiosk](../examples/hello_kiosk/README.md) - example application の詳細
