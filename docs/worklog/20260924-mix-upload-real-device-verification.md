# 2026-09-24 mix upload / persistent data 実機検証

## 目的

PW-SH6 の standard `mix upload` 対応について、次を実機で確認する。

- p2 / p3 の A/B rootfs が交互に更新されること。
- running rootfs を直接上書きしないこと。
- p4 の persistent application data が slot 切り替えをまたいで残ること。
- NervesSSH host key が rootfs 更新で変わらないこと。
- interactive SSH / IEx が通常どおり利用できること。

## fresh burn

A/B + persistent data layout の firmware を `mix burn` で書き込んだ。

起動後の partition は次の構成になった。

```text
/dev/mmcblk1p1   FAT boot
/dev/mmcblk1p2   rootfs A
/dev/mmcblk1p3   rootfs B
/dev/mmcblk1p4   persistent application data
```

fresh boot は p2 / slot A だった。

```text
/proc/cmdline: root=/dev/mmcblk1p2 ...
nerves_fw_active: "a"
```

## p4 の初回 format

最初の確認では p4 自体は作成されていたが `/root` に mount されなかった。
`Nerves.Runtime.Init` が ext4 を初期化するために使う `mkfs.ext4` が target rootfs に入っていなかった。

`nerves_defconfig` には `BR2_PACKAGE_E2FSPROGS=y` を追加済みだったが、既存の `o/.config` が stale だった。
System を clean build した後は次を確認できた。

```text
BR2_PACKAGE_E2FSPROGS=y
/sbin/mkfs.ext4 -> mke2fs
/sbin/mke2fs
```

fresh burn 後、target では p4 が自動で format / mount された。

```text
/dev/mmcblk1p4 on /root type ext4 (rw,relatime)
```

firmware metadata も p4 を application partition として示していた。

```text
nerves_fw_application_part0_devpath = /dev/mmcblk1p4
nerves_fw_application_part0_fstype  = ext4
nerves_fw_application_part0_target  = /root
```

rootfs の `/data -> root` symlink により、`/data/nerves_ssh` も p4 上に置かれる。

## A -> B upload

slot A で起動した状態から standard task を実行した。

```sh
mix upload nerves.local
```

`fwup` は inactive な slot B を選んだ。

```text
fwup: Upgrading rootfs slot B
Success!
```

reboot 後は p3 / slot B になった。

```text
/proc/cmdline: root=/dev/mmcblk1p3 ...
nerves_fw_active: "b"
```

p4 は引き続き `/root` に mount されていた。

## persistent data / SSH identity

p4 上の `/data` に確認用 file を作成した。

```elixir
File.write!("/data/persistence-test", "survives-ab-update")
```

NervesSSH の ED25519 host key fingerprint も記録した。

A -> B upload 後、次を確認した。

- `/data/persistence-test` が残っている。
- `/data/nerves_ssh/ssh_host_ed25519_key` が存在する。
- SSH host key fingerprint が変わらない。
- `known_hosts` を削除せずに再接続できる。

## B -> A upload

slot B から再度 `mix upload nerves.local` を実行し、slot A へ戻した。

```text
/proc/cmdline: root=/dev/mmcblk1p2 ...
nerves_fw_active: "a"
```

A に戻った後も、確認用 file と SSH host key fingerprint は同じだった。

これにより、p4 が A/B rootfs から独立しており、standard `mix upload` の往復で persistent state を
保持できることを確認した。

## interactive IEx と shell history

p4 導入後、SSH transport、public-key authentication、non-interactive Elixir exec は成功する一方、
interactive `ssh nerves.local` が shell request accept 後に停止する現象が出た。

`/etc/iex.exs` と `NervesMOTD.print()` は単独実行できた。OTP 29 の shell history は次を使っていた。

```text
/root/.cache/erlang-history
```

runtime で shell history を無効にすると interactive IEx が即座に開始した。

```elixir
Application.put_env(:kernel, :shell_history, :disabled)
```

既存 history directory を退避して新規作成させても、再度 `:enabled` にすると同じ停止が再現した。
単なる既存 log の破損ではなく、この PW-SH6 / OTP 29 環境では persistent shell history 自体が
interactive SSH/IEx と相性が悪いと判断した。

example の `rel/vm.args.eex` では次を明示する。

```text
-kernel shell_history disabled
```

この変更後、firmware を upload して interactive IEx が通常どおり開始することを確認した。

## 最終確認

repository root で次を実行し、すべて成功した。

```sh
./scripts/check.sh
./scripts/check_fwup.sh
git diff --check
```

実機で確認済みなのは次の範囲である。

- fresh burn -> slot A
- A -> B upload
- B -> A upload
- p4 `/root` mount
- `/data` persistence
- NervesSSH host key persistence
- interactive SSH / IEx (`shell_history disabled`)

## standard runtime firmware operations

追加レビューで、`Nerves.Runtime.FwupOps` が参照する `/usr/share/fwup/ops.fw` が System に無く、
`Nerves.Runtime.firmware_slots/0` が firmware metadata の heuristic fallback を使っていることを確認した。

System の post-build hook で `fwup-ops.conf` から `ops.fw` を生成するようにし、再構築した firmware を
slot B から upload した。slot A で再起動後、次を確認した。

```elixir
File.exists?("/usr/share/fwup/ops.fw")
# => true

Nerves.Runtime.firmware_slots()
# => %{active: "a", next: "a"}

Nerves.Runtime.FwupOps.status()
# => {:ok, %{active: "a", next: "a"}}
```

明示的な revert と validate は、再起動を抑止して selector の往復を確認した。

```elixir
Nerves.Runtime.revert(reboot: false)
# => :ok

Nerves.Runtime.firmware_slots()
# => %{active: "a", next: "b"}

Nerves.Runtime.validate_firmware()
# => :ok

Nerves.Runtime.firmware_slots()
# => %{active: "a", next: "a"}
```

この確認後も `/data/persistence-test` は `{:ok, "survives-ab-update"}` を返した。
`prevent-revert` と `factory-reset` は破壊的なため実機では実行していない。host-side の fwup check では
runtime operation task の存在、非 target host 上での guard、burn-time `NERVES_SERIAL_NUMBER` provisioning を確認した。

この検証では、意図的な upload 中断、NCM 接続中の remote upload、起動不能 firmware を使った manual recovery、
runtime の `prevent-revert` / `factory-reset` は実施していない。automatic rollback も現在の設計には含めない。

現在の設計判断は [ADR 0011](../adr/0011-mix-uploadにはa-b-rootfsとuenv-selectorを使う.md)、
利用手順は [mix upload による firmware 更新](../mix-upload.md) を参照する。
