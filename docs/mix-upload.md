# mix upload による firmware 更新

`nerves_system_brain` は rootfs を A/B の2 slot に分け、通常の Nerves application と同じ
`mix upload` で application firmware を更新する。

## 前提

`mix upload` を使う microSD は、A/B layout 対応後の `mix burn` で作成しておく。
旧 layout は p1 + p2 の2 partition だけなので、そのままでは remote update しない。

```sh
cd examples/hello_kiosk
export MIX_TARGET=brain
mix firmware
mix burn
```

fresh burn の layout は次のとおり。

```text
sector 16-31    Nerves firmware metadata
p1              FAT boot partition
                  edsh6exe.bin
                  zImage
                  imx28-pwsh6.dtb
                  imx28-pwsh6-host.dtb
                  imx28-pwsh6-peripheral.dtb
                  uEnv.txt
                  uEnv.a.txt
                  uEnv.b.txt
p2              ext4 rootfs slot A
p3              ext4 rootfs slot B
```

fresh burn は slot A を起動する。`uEnv.txt` の `sdroot` が p2 / p3 のどちらを次回 boot するかを決める。
起動中の slot は `/proc/cmdline` の `root=/dev/mmcblk1p2` / `p3` でも確認できる。

## 通常の更新

application を変更したら firmware を作り、起動中の PW-SH6 へ upload する。

```sh
cd examples/hello_kiosk
export MIX_TARGET=brain
mix firmware
mix upload nerves.local
```

`NervesSSH` が提供する `fwup` SSH subsystem を使うため、Brain 専用の upload command はない。
この implementation は host-side `fwup` check までを自動化しており、PW-SH6 実機の A -> B -> A 往復は導入時に確認する。
現在 A で起動していれば B に書き、B で起動していれば A に書く。成功後は標準 callback で再起動する。

```text
A(p2) で起動
  -> mix upload
  -> B(p3) へ rootfs を書く
  -> uEnv.txt を B に切り替える
  -> reboot

B(p3) で起動
  -> mix upload
  -> A(p2) へ rootfs を書く
  -> uEnv.txt を A に切り替える
  -> reboot
```

update task は firmware metadata の `nerves_fw_active` だけではなく、実際に mount されている `/` の device と
block offset を確認する。途中で metadata と selector がずれても running rootfs は update target にしない。

## upload で変わらないもの

p1 の boot assets は A/B rootfs で共有する。`mix upload` は次を更新しない。

- `edsh6exe.bin`
- `zImage`
- HOST / NCM の Device Tree
- active `imx28-pwsh6.dtb`

そのため USB mode も upload 前の状態を維持する。NCM で接続して upload した場合は reboot 後も NCM、
HOST で接続した場合は HOST のままである。

kernel / DTB / loader を変更した場合は remote upload ではなく、microSD を Linux PC に接続して
`mix burn` で current firmware を書き直す。

## 中断時の考え方

rootfs は inactive slot に先に全体を書き、slot metadata を記録する。boot selector の `uEnv.txt` は
全 firmware resource の受信が完了した後の `on-finish` で切り替える。

selector の更新も直接上書きせず、reference file を `uEnv.txt.new` にコピーしてから rename する。
そのため upload 中断時は、可能な限り現在の selector を保持する。

automatic rollback は現段階では実装していない。update 自体が成功しても、新 application が起動後に
失敗するケースは自動では前 slot に戻らない。

## manual recovery

新しい slot が boot しない場合は電源を切り、microSD を Linux PC に接続する。FAT p1 には両 slot の
selector reference が残っている。

```text
uEnv.a.txt  -> p2 / slot A
uEnv.b.txt  -> p3 / slot B
```

前に動いていた側の file を `uEnv.txt` にコピーしてから microSD を PW-SH6 に戻す。
例えば A に戻す場合は、p1 を mount した状態で次のようにする。

```sh
cp uEnv.a.txt uEnv.txt
sync
```

実際の mount path で実行し、対象が microSD の FAT boot partition であることを確認する。

## 実機確認項目

A/B update を変更した場合は、少なくとも次を PW-SH6 で確認する。

- fresh `mix burn` から slot A が起動する。
- A から `mix upload` して slot B が起動する。
- B から `mix upload` して slot A が起動する。
- NCM で upload しても active DTB が NCM のまま残る。
- HOST で upload しても active DTB が HOST のまま残る。
- upload 中断時に running slot が上書きされない。
- manual recovery で前 slot に戻せる。

設計判断は [ADR 0011](adr/0011-mix-uploadにはa-b-rootfsとuenv-selectorを使う.md) を参照する。
