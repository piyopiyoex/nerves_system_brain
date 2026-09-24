# 2026-09-24 automatic rollback 実装・実機検証

## 目的

PR #45 で導入した A/B rootfs と standard `mix upload` に、固定 buildbrain U-Boot を交換せず automatic rollback を追加する。

確認対象は次のとおり。

- 既存 A/B media から再 burn なしで移行できること。
- 新 firmware が unvalidated な one-shot boot になること。
- application startup 成功後に Nerves Runtime の standard API で確定すること。
- one-shot 候補を起動する前に旧 slot が次回 boot として永続化されること。
- 次の reboot で旧 slot に戻ること。
- p4 の persistent data が維持されること。

## 固定 U-Boot の確認

利用中の buildbrain `2026-03-25-024518` release は、buildbrain
`3fb1dea6f15ac35023a285814c0e161b17e77f3d` と u-boot-brain
`e8fc0d0cf39d9cd06245ef1777d1cf54258e5cb6` に対応する。

PW-SH6 defconfig と実 binary を確認し、次が利用可能だった。

- `CONFIG_ENV_SIZE=0x4000`
- text `uEnv.txt` import
- `env import -c` / `env export -c`
- raw `mmc read` / `mmc write`

bootcount / altbootcmd はないため、sector 32-63 に U-Boot 専用の 16 KiB environment を追加し、
`brain_boot_state` 1変数を one-shot state とした。sector 16-31 の Nerves firmware metadata は従来の8 KiB のまま保つ。

## one-shot の動作

state は `a`、`b`、`try-a`、`try-b` の4値である。例えば A で起動中に B を更新した場合は次になる。

```text
mix upload
  -> B rootfs を書く
  -> b.nerves_fw_validated=0
  -> uEnv.txt の既定 fallback は A
  -> brain_boot_state=try-b

次の U-Boot
  -> try-b を読む
  -> brain_boot_state=a を先に永続化
  -> B を一度だけ起動

B startup 成功
  -> Nerves.Runtime.StartupGuard
  -> Nerves.Runtime.validate_firmware()
  -> b.nerves_fw_validated=1
  -> brain_boot_state=b
```

state environment を読めない場合、`uEnv.auto-a.txt` / `uEnv.auto-b.txt` はそれぞれ確定済み fallback を既定値にする。
さらに `uEnv.a.txt` / `uEnv.b.txt` は state を読まず slot を強制する manual recovery 用として残した。

## host-side 検証

次を実行して成功した。

```sh
./scripts/check.sh
./scripts/check_fwup.sh
mix format --check-formatted
mix test
mix brain.system.build
MIX_ENV=prod MIX_TARGET=brain mix firmware
```

`check_fwup.sh` は次も確認する。

- pinned U-Boot binary に必要な environment / MMC command が存在する。
- fresh burn が automatic selector と forced selector を配置する。
- 16 KiB state environment が読み書きできる。
- state environment の更新が8 KiB の Nerves metadata を変更しない。

## 既存 media からの upload

実機は PR #45 の firmware で slot A から起動していた。

```text
root=/dev/mmcblk1p2
nerves_fw_active=a
a.nerves_fw_validated=1
b.nerves_fw_validated=1
```

生成した firmware を通常の経路で送った。

```sh
MIX_ENV=prod MIX_TARGET=brain mix upload 192.168.10.103
```

fwup は `upgrade.b` を選び、upload と標準 callback の reboot は成功した。再 burn は行っていない。

slot B の startup 後は次だった。

```text
root=/dev/mmcblk1p3
brain_boot_state=b
Nerves.Runtime.firmware_slots() == %{active: "b", next: "b"}
Nerves.Runtime.firmware_validation_status() == :validated
```

StartupGuard task は validation 後に正常終了しており、heart callback も解除されていた。B の metadata と boot state が
ともに確定済みになったことから、standard validate task が完了したことを確認した。

## one-shot fallback の分離確認

rootfs を壊さず state machine を分離確認するため、B 上で state を `try-a` にして reboot した。

1回目の reboot は slot A を起動したが、その boot の U-Boot が既に B を次回 state として保存していた。

```text
root=/dev/mmcblk1p2
brain_boot_state=b
Nerves.Runtime.firmware_slots() == %{active: "a", next: "b"}
```

もう一度通常 reboot すると B へ戻った。

```text
root=/dev/mmcblk1p3
brain_boot_state=b
Nerves.Runtime.firmware_slots() == %{active: "b", next: "b"}
Nerves.Runtime.firmware_validation_status() == :validated
```

全段階で `/data/persistence-test` は `survives-ab-update` を保持した。

## 最終 firmware の reverse upload

pending state の slot 表示を追加した最終 firmware を生成し、slot B から同じ standard
`mix upload` を実行した。fwup は `upgrade.a` を選択し、upload、reboot、StartupGuard による
validation は成功した。

```text
root=/dev/mmcblk1p2
brain_boot_state=a
Nerves.Runtime.firmware_slots() == %{active: "a", next: "a"}
Nerves.Runtime.firmware_validation_status() == :validated
nerves_fw_active=a
a.nerves_fw_validated=1
```

reboot せず `brain_boot_state=try-b` とした pending state では、standard API が次を返した。

```text
Nerves.Runtime.firmware_slots() == %{active: "a", next: "b"}
```

state を `a` に戻すと `%{active: "a", next: "a"}` に復帰した。実機は最終的に validated A / state `a`
とし、`/data/persistence-test` は引き続き `survives-ab-update` を保持している。

## 未確認範囲

- application startup を意図的に失敗させ、StartupGuard の15分 timeout から heart reboot する end-to-end 試験。
- kernel hang から hardware watchdog で reset する動作。現在 hardware watchdog は設計に含めない。
- upload / U-Boot state write の最中に意図的に電源を切る fault injection。
- `prevent-revert` / `factory-reset`。いずれも破壊的なため実機では実行していない。

設計判断は [ADR 0012](../adr/0012-one-shot-boot-stateでautomatic-rollbackを行う.md)、利用手順は
[mix upload による firmware 更新](../mix-upload.md) を参照する。
