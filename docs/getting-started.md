# 初回セットアップ: PW-SH6 で hello_kiosk を動かす

このガイドでは、`nerves_system_brain` をビルドして microSD に配置し、
SHARP Brain PW-SH6 で `examples/hello_kiosk` を起動するまでを説明する。

初回は、Brain と Linux PC を microUSB ケーブルで直接接続する **USB-NCM** 構成を使用する。

> **注意**: microSD への書き込みでは、指定したデバイスの内容を消去する。
> 書き込み先を必ず確認すること。本体 eMMC には書き込まない。

## 1. 用意するもの

- Linux PC (`sudo` が使える環境)
- SHARP Brain PW-SH6
- microSD カードとカードリーダー
- **データ通信対応**の microUSB ケーブル
- `git`
- [mise](https://mise.jdx.dev/) または asdf

## 2. System をビルドする

```sh
git clone https://github.com/piyopiyoex/nerves_system_brain.git
cd nerves_system_brain

git clone --branch v1.34.3 --depth 1 \
  https://github.com/nerves-project/nerves_system_br.git ../nerves_system_br

../nerves_system_br/create-build.sh nerves_defconfig o
make -C o
```

初回は OTP 29 の ARMv5 クロスビルドを含むため時間がかかる。

## 3. hello_kiosk release をビルドする

```sh
cd examples/hello_kiosk
mise trust
mise install
./scripts/setup_ssh.sh
./scripts/build_release.sh
cd ../..
```

asdf を使う場合は `.tool-versions` の Erlang / Elixir を asdf でインストールする。

## 4. buildbrain の SD イメージを用意する

[brain-hackers/buildbrain releases](https://github.com/brain-hackers/buildbrain/releases) から
`sdimage-*.zip` をダウンロードし、`sd/` に展開する。

```sh
unzip /path/to/sdimage-*.zip -d sd/
```

## 5. microSD を作成する

カードリーダーを接続し、microSD のデバイス名を確認する。

```sh
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS,MODEL
```

以下では `/dev/sdX` とする。実際の microSD のデバイス名に読み替える。

### 5.1 ベースイメージを書き込む

自動マウントされているパーティションがあればアンマウントしてから、
イメージをディスク全体へ書き込む。

```sh
sudo dd if=sd/sdimage-*.img of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

### 5.2 Nerves System を配置する

```sh
sudo bash sd/populate_sd.sh /dev/sdX
```

### 5.3 USB-NCM 用 Device Tree を配置する

```sh
sudo bash sd/use_usb_ncm.sh /dev/sdX
```

USB role は Device Tree で決まり、userspace の network setup もそれに追従する。
`erlinit.config` の手作業による切り替えは不要。

host / peripheral の詳細は [PW-SH6 の Device Tree](../sd/README.md) を参照。

### 5.4 hello_kiosk を配置する

```sh
sudo bash sd/deploy_release.sh /dev/sdX \
  examples/hello_kiosk/_build/prod/rel/hello_kiosk_brain
```

## 6. PW-SH6 を起動する

1. microSD を PW-SH6 に挿入する。
2. データ通信対応の microUSB ケーブルで PW-SH6 と Linux PC を接続する。
3. PW-SH6 を起動する。
4. LCD に KIOSK 画面が表示されることを確認する。

## 7. Linux PC から接続する

PW-SH6 の起動後、Linux PC に追加された USB network interface を確認する。

```sh
ip -br link
```

その interface に `10.42.0.1/24` を設定する。

```sh
sudo ip addr replace 10.42.0.1/24 dev <USBインターフェース>
ping -c 3 10.42.0.2
```

疎通できたら SSH で接続する。

```sh
ssh user@10.42.0.2
```

公開鍵認証を設定していない場合、パスワードは `brain`。正常なら対話 IEx が開く。

Elixir 式を1回だけ実行することもできる。

```sh
ssh user@10.42.0.2 'node()'
```

ファイル転送には SFTP を使用できる。

```sh
sftp user@10.42.0.2
```

## 8. うまく接続できない場合

USB network interface が現れない場合は、まず次を確認する。

- microUSB ケーブルがデータ通信対応か。
- `sd/use_usb_ncm.sh /dev/sdX` を実行したか。
- ケーブルを一度抜き差しする。

SSH が `Connection refused` になる場合は、起動直後の可能性がある。
SSH daemon は少し遅れて起動するため、10〜15秒待って再試行する。

同じ IP で以前の SD カードに接続して host key warning が出る場合は、古い key を削除する。

```sh
ssh-keygen -R 10.42.0.2
```

## 関連ドキュメント

- [nerves_system_brain](../README.md) - リポジトリ全体の概要
- [アーキテクチャ概要](README.md) - 設計方針と全体像
- [PW-SH6 の erlinit bring-up profile](erlinit.md) - `erlinit` と起動処理
- [PW-SH6 の Device Tree](../sd/README.md) - host / peripheral の選択
- [アプリケーション release の作成と配置](release-deployment.md) - release の要件と配置
- [hello_kiosk](../examples/hello_kiosk/README.md) - example application の詳細
