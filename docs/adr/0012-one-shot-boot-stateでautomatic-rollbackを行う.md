# 0012: one-shot boot state で automatic rollback を行う

## 状態

採用

## 背景

ADR 0011 では、固定して利用する buildbrain の PW-SH6 U-Boot に bootcount / altbootcmd がないため、
書き込み済み firmware を即座に validated とし、起動失敗時は p1 の selector を Linux PC で戻す方針とした。

固定 U-Boot を改めて確認すると、`uEnv.txt` の text environment import に加えて、CRC 付き environment の
`env import -c` / `env export -c` と raw `mmc read` / `mmc write` が利用できる。U-Boot 自体を差し替えず、
候補 slot を一度だけ試す永続状態を boot script から消費できる。

Nerves Runtime 0.13 は `Nerves.Runtime.StartupGuard` を提供する。候補 firmware を unvalidated として起動し、
release の全 OTP application が起動した後に standard `Nerves.Runtime.validate_firmware/0` で確定できる。
起動が完了しない場合は Erlang heart が再起動し、次の boot で fallback を選べる。

## 決定

pre-partition gap に用途を分けた2つの U-Boot-format environment を置く。

- sector 16-31 (8 KiB): Nerves Runtime の firmware metadata。従来どおり Linux / fwup が管理する。
- sector 32-63 (16 KiB): U-Boot 専用の one-shot boot state。固定 U-Boot の
  `CONFIG_ENV_SIZE=0x4000` に合わせる。

boot state は `brain_boot_state` 1変数だけとし、値を次のように扱う。

- `a` / `b`: 確定済みの次回 boot slot。
- `try-a`: A を一度試し、その直前に B を次回 boot として永続化する。
- `try-b`: B を一度試し、その直前に A を次回 boot として永続化する。

p1 には2種類の selector を置く。

- `uEnv.auto-a.txt` / `uEnv.auto-b.txt`: boot state を読み、one-shot 試行を消費する通常 selector。
  state block を読めない場合の既定値がそれぞれ A / B であり、確定済み fallback と一致させる。
- `uEnv.a.txt` / `uEnv.b.txt`: boot state を読まず A / B を直接選ぶ manual recovery selector。

`mix upload` は実行中の validated slot の反対側へ rootfs を書き、新 slot を `validated=0` とする。
全 resource の受信後に、実行中 slot の automatic selector を `uEnv.txt` に残したまま boot state を
`try-a` / `try-b` にする。U-Boot は候補を起動する前に fallback state を書き戻すため、候補が確定処理へ
到達しなければ次の再起動で旧 slot を選ぶ。

`fwup-ops.conf` の validate / revert / prevent-revert は、firmware metadata、automatic selector、boot state を
同じ操作で更新する。status は実際に mount された rootfs と boot state から current / next slot を返す。

application は標準の validation flow を使う。example では次を有効にする。

```elixir
config :nerves_runtime, startup_guard_enabled: true
```

VM では Erlang heart と startup handshake timeout を有効にする。

```text
-env HEART_INIT_TIMEOUT 600
-heart -env HEART_BEAT_TIMEOUT 30
```

## 理由

- `mix firmware` / `mix upload`、NervesSSH、`Nerves.Runtime.FwupOps`、StartupGuard という標準の利用面を維持できる。
- 固定 U-Boot binary の fork や差し替えを必要としない。
- Nerves metadata を U-Boot に書き戻さないため、8 KiB の既存 metadata format と provisioning data を維持できる。
- U-Boot が書く state を1変数の専用 16 KiB environment に限定できる。
- 候補を起動する前に fallback を永続化するため、rootfs / kernel 起動失敗後の reset でも旧 slot を選べる。
- automatic selector と別に forced selector を残すため、state block 自体が壊れても Linux PC から復旧できる。
- PR #45 の A/B layout を作成済みの media も、最初の `mix upload` が selector reference と state block を
  初期化するため、再 burn せず移行できる。

## 影響

- upload 後の候補 slot は、application が validation を完了するまで unvalidated である。
- unvalidated slot で `Nerves.Runtime.firmware_slots/0` を呼ぶと、`active` は候補、`next` は fallback になる。
- current firmware が validated でなければ、次の upload は拒否する。
- StartupGuard が全 release application の起動を確認すると、自動で running slot を確定する。
- StartupGuard 登録後に application startup が止まった場合、heart の timeout 後に再起動して fallback する。
- kernel が完全に停止するなど software reboot に到達できない故障では、hardware watchdog は追加していないため、
  reset または電源再投入が必要である。ただし候補起動前に fallback は既に arm されている。
- shared kernel / DTB / loader は従来どおり `mix upload` の対象外である。

ADR 0011 の「automatic rollback を導入せず、書き込み成功時点で validated とする」という判断は、
この ADR で置き換える。A/B layout、persistent data、standard upload transport に関する残りの判断は維持する。

## 再評価条件

- hardware watchdog を使い、kernel hang からも無人で reset する必要が生じた場合。
- 1回ではなく複数回の候補 boot attempt が必要になった場合。
- fixed U-Boot を更新し、bootcount / altbootcmd または redundant environment を正式に利用できる場合。
- application health の条件を「全 OTP application が起動」より厳しくする必要が生じた場合。
