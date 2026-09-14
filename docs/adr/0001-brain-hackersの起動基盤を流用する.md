# 0001: brain-hackers の起動基盤を流用する

## 状態

採用

## 背景

PW-SH6 は ARM926EJ-S を搭載した独自性の高い機器であり、起動処理、液晶、入力装置などに
専用の対応を必要とする。brain-hackers の buildbrain には、PW-SH6 で動作実績のある
U-Boot、Linux カーネル、Device Tree、SD カード構成がある。

ハードウェア立ち上げと同時にこれらを置き換えると、問題が起動基盤と Nerves rootfs の
どちらにあるかを切り分けにくくなる。

## 決定

当面は buildbrain 2026-03-25 リリース系の U-Boot、Linux カーネル、Device Tree、
SD カードの区画構成を基盤として流用する。Nerves 側では rootfs を生成し、buildbrain の
rootfs と差し替える。

Device Tree の変更は、USB gadget に必要な `dr_mode = "peripheral"` など、実機で必要性を
確認した最小限の差分に限定する。

## 理由

- PW-SH6 で確認済みの起動経路と専用ドライバを維持できる。
- Nerves rootfs に起因する問題を、カーネルや U-Boot の問題から分離できる。
- 早期の立ち上げ段階で、カーネルとブートローダーの保守まで同時に抱えずに済む。

## 影響

- このリポジトリだけでは起動可能な SD イメージを生成できず、指定した buildbrain の
  成果物が必要となる。
- buildbrain のリリースと成果物を明示的に固定し、由来を記録する必要がある。
- カーネル、Device Tree、起動処理を変更する場合は、PW-SH6 実機での再検証が必要となる。
- 完全な Nerves のファームウェア生成方式への移行は必須とはせず、必要性が生じた場合に再評価する。

## 再評価条件

- `nerves_system_brain` 単体で再現可能な firmware を生成する必要が生じた場合。
- brain-hackers の固定成果物では必要な kernel / bootloader 機能を満たせなくなった場合。
- kernel や U-Boot を本プロジェクト側で保守する利点が、その検証・保守コストを上回る場合。
