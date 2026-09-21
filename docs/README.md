# アーキテクチャ概要

`nerves_system_brain` は SHARP Brain PW-SH6 上で Nerves/Elixir を動かすためのカスタム
Nerves システムである。現在の構成は「公式 Nerves System と同じ形にすること」自体を目的にせず、
**Nerves の標準的な仕組みを使えるところでは使い、PW-SH6 固有の制約があるところだけを
明示的にカスタマイズする**方針を取る。

標準 Nerves との差異は、それだけでは未完了事項や技術的負債を意味しない。差異ごとに、
ハードウェア上必要な設計なのか、立ち上げ段階の選択なのか、標準機構へ寄せる価値があるのかを
ADR で判断する。

## 現在の全体像

```text
examples/hello_kiosk
    Nerves application / KIOSK UI / 入力 / SSH / NIF
             │
             │ MIX_TARGET=brain
             ▼
nerves_system_brain
    Nerves System interface / Buildroot rootfs / Erlang/OTP / erlinit / OS 設定
             │
             ▼
brain-hackers の起動基盤
    U-Boot / Linux kernel / Device Tree / SD boot
             │
             ▼
SHARP Brain PW-SH6
```

現在は brain-hackers の実績ある起動基盤を流用し、その上の rootfs と Erlang/OTP を
`nerves_system_brain` が提供する。`align-with-nerves-way` では通常の Nerves System dependency
として `examples/hello_kiosk` から参照できる PoC も成立している。アプリケーション例の
`hello_kiosk` は同じリポジトリに置くが、システム側から依存しない。

## Nerves 標準に沿っている部分

- `nerves_system_br` / Buildroot external tree を基盤にする。
- `nerves_defconfig` でターゲットの Buildroot 設定を管理する。
- `rootfs_overlay/` でターゲット固有ファイルを追加する。
- application networking は `NervesPack` / `VintageNet` / `NervesSSH` を使用する。
- PID 1 と Erlang 起動に `erlinit` を使用する。
- System とアプリケーションの責務を分離する。
- `type: :system`、`MIX_TARGET=brain`、`Nerves.Release.erts/0`、`mix firmware` を使った
  target application flow を提供する。

## PW-SH6 固有として受け入れている部分

- U-Boot / Linux kernel / Device Tree は brain-hackers の実績ある成果物を基盤にする。
- ARMv5 soft-float 用に Bootlin の ARMv5 glibc toolchain を使用する。
- 現在の rootfs は ext4 とし、立ち上げ・診断に必要な書き込みを許容する。
- 開発用の標準通信経路は USB-NCM とする。USB gadget の生成は System 固有処理として残し、
  address / DHCP は application 側の `VintageNetDirect` が管理する。
- Buildroot output は当面 `o/` を再利用する。portable system artifact と Linux x86_64 toolchain
  artifact のローカル生成・利用は確認済みで、両 artifact の公開は今後の課題とする。

これらは「まだ Nerves らしくないから直す項目」ではなく、現在採用している設計判断である。
背景と再評価条件は [`adr/`](adr/) を参照する。

## 標準化を検討できる候補

以下は将来の **検討候補** であり、現在の未完了タスクとは限らない。

- Nerves System / toolchain artifact の公開
- `fwup` による blank SD 作成・更新
- SD 配備フローの統合
- read-only rootfs / A/B 更新

必要性が生じた時点で、PW-SH6 の制約と得られる利点を比較して ADR として判断する。

## 読む順番

1. この文書で全体像をつかむ。
2. [`adr/README.md`](adr/README.md) で現在の設計判断を確認する。
3. 動作例の実機知見は [`../examples/hello_kiosk/docs/`](../examples/hello_kiosk/docs/) を参照する。
