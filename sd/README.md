# PW-SH6 の device tree

## 管理方針

このディレクトリでは DTS を正として管理し、同名の DTB を生成物として併せて保持する。
DTB を直接編集してはならない。通常使用する構成は
`imx28-pwsh6-peripheral.dts` と `imx28-pwsh6-peripheral.dtb` である。

生成済み DTB を保持するのは、SD カードの作成時に Linux kernel のソースツリーや `dtc` を
必要とせず、実機検証済みの起動環境を利用できるようにするためである。

## ファイル

| DTS | 生成する DTB | 用途 | 扱い |
|---|---|---|---|
| `imx28-pwsh6-peripheral.dts` | `imx28-pwsh6-peripheral.dtb` | USB0 を peripheral mode にして USB NCM を使用する | 標準構成 |
| `imx28-pwsh6-buzzer.dts` | `imx28-pwsh6-buzzer.dtb` | 標準構成に加えて `buzzer_cold` と `buzzer` を有効にする | 実験用 |

buzzer 版では `pwm-beeper` が入力機器として認識されることまでは確認されているが、発音は
確認されていない。通常の起動では peripheral 版を使用する。

## 出典と派生関係

基になった DTB は [buildbrain 2026-03-25-024518 リリース](https://github.com/brain-hackers/buildbrain/releases/tag/2026-03-25-024518)
の `linux-2026-03-25-024518.zip` に含まれる `imx28-pwsh6.dtb` である。元の DTB の SHA-256 は
`c45cc5cccd9047f00283aca3e276bedd0f3468f10f55a766dcad20abff0a2df0` である。このリリースが
参照する Linux ソースは [brain-hackers/linux-brain の commit `a9f534c`](https://github.com/brain-hackers/linux-brain/blob/a9f534c7f53e7ee6bb2cb3581fd471cc964f1601/arch/arm/boot/dts/imx28-pwsh6.dts)
である。

本リポジトリの DTS はリリースの DTB を逆コンパイルした展開済みのソースを基にしている。
`imx28-pwsh6-peripheral.dts` は USB0 の `dr_mode` を `host` から `peripheral` に変更したもの、
`imx28-pwsh6-buzzer.dts` はさらに `buzzer_cold` と `buzzer` の `status` を `disabled` から
`okay` に変更したものである。

## DTB の生成

`dtc` が `PATH` にある環境で、次のコマンドを実行する。

```sh
make -B -C sd
```

Makefile は、逆コンパイルした DTS に由来する既知の警告を `-q` で省略する。構文エラーなどは
失敗として扱われる。警告を確認する場合は次のように実行する。

```sh
make -B -C sd DTC_FLAGS=
```

生成後は意図しない DTB の変更がないことを確認する。

```sh
git diff --exit-code -- sd/*.dtb
```

## SD カードへの配置

U-Boot が読み込む名前に合わせ、選択した DTB をブートパーティションの
`imx28-pwsh6.dtb` として配置する。現在の `populate_sd.sh` は DTB をコピーしないため、標準構成は
次のように別途配置する。`<boot-mount>` はブートパーティションのマウントポイントに置き換える。

```sh
sudo cp sd/imx28-pwsh6-peripheral.dtb <boot-mount>/imx28-pwsh6.dtb
sync
```

buzzer 版は実験するときだけ選択する。DTS または DTB の内容を変更した場合は、起動、USB NCM、
対象周辺機器への影響を PW-SH6 実機で確認する必要がある。
