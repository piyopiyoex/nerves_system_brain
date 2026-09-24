# mix upload による firmware 更新

`nerves_system_brain` は rootfs を A/B の2 slot に分け、通常の Nerves application と同じ
`mix upload` で application firmware を更新する。rootfs と独立した p4 を persistent data として使い、
slot を切り替えても `/data` を保持する。

## 前提

`mix upload` を使う microSD は、A/B + persistent data layout 対応後の `mix burn` で作成しておく。
旧 layout は p1 + p2 の2 partition だけなので、そのまま remote update しない。

```sh
cd examples/hello_kiosk
export MIX_TARGET=brain
mix firmware
mix burn
```

fresh burn の layout は次のとおり。

```text
sector 16-31    Nerves firmware metadata
sector 32-63    U-Boot one-shot boot state
p1              FAT boot partition
                  edsh6exe.bin
                  zImage
                  imx28-pwsh6.dtb
                  imx28-pwsh6-host.dtb
                  imx28-pwsh6-peripheral.dtb
                  uEnv.txt
                  uEnv.a.txt
                  uEnv.b.txt
                  uEnv.auto-a.txt
                  uEnv.auto-b.txt
p2              ext4 rootfs slot A (256 MiB)
p3              ext4 rootfs slot B (256 MiB)
p4              ext4 persistent application data
                  256 MiB minimum, remaining capacity まで expand
                  /root に mount
```

fresh burn は slot A を起動する。`uEnv.txt` と one-shot boot state が p2 / p3 のどちらを次回 boot するかを決める。
起動中の slot は `/proc/cmdline` の `root=/dev/mmcblk1p2` / `p3` でも確認できる。

製造時などに device serial number を設定する場合は、firmware を作り直さず burn 時に渡せる。

```sh
NERVES_SERIAL_NUMBER=brain-0001 mix burn
```

値は firmware archive には保存されず、`complete` task の provisioning hook が firmware metadata に書き込む。

p4 は firmware metadata の application partition として定義する。fresh burn では filesystem signature を
消去し、初回起動時に `Nerves.Runtime` が ext4 として format して `/root` に mount する。
rootfs の `/data -> root` symlink により、`/data` 配下は p4 に置かれる。NervesSSH の host key も
`/data/nerves_ssh` に保存されるため、A/B slot をまたいで継続する。

`mix upload` は p4 を変更しない。一方、fresh `mix burn` は p4 も再初期化するため、p4 の data を
re-provisioning をまたいで保持したい場合は事前に退避する。

## 通常の更新

application を変更したら firmware を作り、起動中の PW-SH6 へ upload する。

```sh
cd examples/hello_kiosk
export MIX_TARGET=brain
mix firmware
mix upload nerves.local
```

`NervesSSH` が提供する `fwup` SSH subsystem を使うため、Brain 専用の upload command はない。
現在 A で起動していれば B に書き、B で起動していれば A に書く。成功後は標準 callback で再起動する。

```text
A(p2) で起動
  -> mix upload
  -> B(p3) へ rootfs を書く
  -> B を unvalidated な one-shot boot として予約
  -> reboot
  -> U-Boot は次回を A に戻してから B を起動
  -> application startup 成功後に B を validate

B(p3) で起動
  -> mix upload
  -> A(p2) へ rootfs を書く
  -> A を unvalidated な one-shot boot として予約
  -> reboot
  -> U-Boot は次回を B に戻してから A を起動
  -> application startup 成功後に A を validate
```

update task は firmware metadata の `nerves_fw_active` だけではなく、実際に mount されている `/` の device と
block offset を確認する。途中で metadata と selector がずれても running rootfs は update target にしない。
また、running slot が validated であることを要求する。未確定の候補を実行中に重ねて upload はできない。

PR #45 の A/B layout で作成済みの media は再 burn を必要としない。automatic rollback 対応 firmware を最初に
upload したとき、automatic selector reference と one-shot boot state を追加して移行する。

## upload で変わらないもの

p1 の boot assets は A/B rootfs で共有する。`mix upload` は次を更新しない。

- `edsh6exe.bin`
- `zImage`
- HOST / NCM の Device Tree
- active `imx28-pwsh6.dtb`
- p4 の persistent application data

そのため USB mode は upload 前の状態を維持し、`/data` と NervesSSH host key も slot 切り替えをまたいで
保持される。

kernel / DTB / loader を変更した場合は remote upload ではなく、microSD を Linux PC に接続して
`mix burn` で current firmware を書き直す。`mix burn` は p4 も再初期化する点に注意する。

## 中断時の考え方

rootfs は inactive slot に先に全体を書き、slot metadata を unvalidated として記録する。automatic selector と
one-shot boot state は全 firmware resource の受信が完了した後の `on-finish` で有効化する。

selector の更新も直接上書きせず、reference file を `uEnv.txt.new` にコピーしてから rename する。
upload が selector 切り替え前に中断した場合は、current slot を引き続き選択する。

候補 slot の boot では、U-Boot が kernel を起動する前に旧 slot を次回 boot として永続化する。候補の
全 OTP application が起動すると `Nerves.Runtime.StartupGuard` が `validate_firmware/0` を呼び、候補を確定する。
起動が完了しなければ Erlang heart が再起動し、旧 slot に戻る。

kernel が完全に停止するなど software reboot 自体に到達できない場合、hardware watchdog はないため reset または
電源再投入が必要になる。この時点でも fallback は候補起動前に arm 済みなので、次の boot は旧 slot になる。

## Nerves.Runtime の firmware 操作

System rootfs は `/usr/share/fwup/ops.fw` を含むため、`Nerves.Runtime` の standard firmware slot API を使える。

```elixir
Nerves.Runtime.firmware_slots()
# => %{active: "a", next: "a"}

# tentative B の起動中は、validation まで fallback A が next になる
# => %{active: "b", next: "a"}

Nerves.Runtime.revert()
# valid な inactive slot を次回 boot に選び、再起動する

Nerves.Runtime.validate_firmware()
# running slot を validated として記録する
```

`Nerves.Runtime.FwupOps.prevent_revert/0` は inactive slot を無効化し、
`Nerves.Runtime.FwupOps.factory_reset/0` は p4 の filesystem signature を消去して再起動する。
後者は次回起動時に p4 を再 format するため、persistent data を失う破壊的な操作である。

application 側で automatic validation を使うには `Nerves.Runtime.StartupGuard` と Erlang heart を有効にする。
`examples/hello_kiosk` はその設定例を含む。network reachability など application 固有の health 条件が必要なら、
StartupGuard を置き換え、成功時だけ `Nerves.Runtime.validate_firmware/0` を呼ぶ。

## manual recovery

automatic fallback でも起動できない場合は電源を切り、microSD を Linux PC に接続する。FAT p1 には boot state を
読まずに両 slot を直接選ぶ forced selector reference が残っている。

```text
uEnv.a.txt  -> p2 / slot A を強制
uEnv.b.txt  -> p3 / slot B を強制
```

前に動いていた側の file を `uEnv.txt` にコピーしてから microSD を PW-SH6 に戻す。
例えば A に戻す場合は、p1 を mount した状態で次のようにする。

```sh
cp uEnv.a.txt uEnv.txt
sync
```

実際の mount path で実行し、対象が microSD の FAT boot partition であることを確認する。

## 2026-09-24 実機確認

PW-SH6 と `hello_kiosk` で次を確認した。

- fresh `mix burn` から slot A / p2 が起動した。
- A から `mix upload` して slot B / p3 が起動した。
- B から `mix upload` して slot A / p2 に戻った。
- p4 が `/root` に ext4 で mount され、A/B 往復後も mount が維持された。
- `/data` に作成した確認用 file が A/B 往復後も残った。
- NervesSSH の ED25519 host key が A/B 往復後も同一で、`known_hosts` の削除を必要としなかった。
- `ops.fw` 経由の `firmware_slots/0` / status が current / next slot を返した。
- reboot を抑止した明示的な revert で A -> B を予約し、validate で A -> A に戻せた。
- host-side `scripts/check_fwup.sh` で `complete`、USB mode task、`upgrade` guard を確認した。

この確認は automatic rollback 導入前に行ったものである。意図的な upload 中断、NCM 接続中の remote upload、
起動不能 firmware を使った manual recovery、runtime の `prevent-revert` / `factory-reset` は実施していない。

検証の詳細は
[2026-09-24 mix upload / persistent data 実機検証](worklog/20260924-mix-upload-real-device-verification.md) を参照する。

automatic rollback 追加後は、既存 media からの `mix upload`、candidate の validation、one-shot A boot が
fallback B を事前に arm すること、次の reboot で B に戻ることを実機確認した。詳細は
[2026-09-24 automatic rollback 実装・実機検証](worklog/20260924-automatic-rollback-real-device-verification.md) を参照する。

設計判断は [ADR 0011](adr/0011-mix-uploadにはa-b-rootfsとuenv-selectorを使う.md) と
[ADR 0012](adr/0012-one-shot-boot-stateでautomatic-rollbackを行う.md) を参照する。
