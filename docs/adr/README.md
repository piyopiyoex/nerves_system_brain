# アーキテクチャ決定記録

[`docs/README.md`](../README.md) で説明する全体方針を、個別の設計判断として記録する。

このプロジェクトでは **「公式 Nerves System と異なる = 未完成」ではない**。PW-SH6 固有の
制約による差異は設計として受け入れ、標準機構へ寄せる価値が出たときだけ再評価する。

## 決定マップ

| 番号 | 問い | 現在の判断 |
|---|---|---|
| [0001](0001-brain-hackersの起動基盤を流用する.md) | Nerves より下の起動基盤をどうするか | brain-hackers の実績ある U-Boot / kernel / DT を流用する |
| [0002](0002-bootlin-armv5ツールチェーンを採用する.md) | ARMv5 用ソフトウェアを何でビルドするか | Bootlin ARMv5 glibc toolchain を使う |
| [0003](0003-rootfsにext4を採用する.md) | rootfs をどう構成するか | ext4 を使い、現段階では書き込み可能とする |
| [0004](0004-usb-ncmを開発用通信経路とする.md) | 開発時にどう通信するか | USB-NCM を標準の開発経路とする |
| [0005](0005-nerves-system-brをstandaloneで利用する.md) | Nerves System をどう組み立てるか | `nerves_system_br` を standalone で利用する |
| [0006](0006-nerves標準開発フローへ段階移行する.md) | application 開発体験を標準 Nerves に寄せるか | boot/storage は維持し、System dependency 化から段階移行する |
| [0007](0007-blank-sd-provisioningとa-b-updateを分離する.md) | blank SD provisioning と安全な更新をどう進めるか | fixed boot bundle で初回作成を完結し、A/B update は別設計にする |
| [0008](0008-networkingをvintagenetへ移行する.md) | network interface を誰が管理するか | hardware setup は System、IP/DHCP/WiFi は VintageNet / NervesPack が管理する |
| [0009](0009-host側のusbモード切り替えにfwup-taskを使う.md) | Linux PC から USB モードをどう選ぶか | `fwup` task を `mix burn --task` から適用する |

これらは現在の採用判断であり、表にある標準化候補を自動的な TODO にはしない。
各 ADR の「再評価条件」に該当したときに見直す。

## ADR の書き方

ADR は4桁の連番を付け、原則として次の構成で記述する。

```markdown
# NNNN: タイトル

## 状態

採用

## 背景

## 決定

## 理由

## 影響

## 再評価条件
```

実装手順、調査中の仮説、短期間だけ有効な作業記録は ADR に含めない。採用済みの判断を
変更する場合は既存 ADR を書き換えず、新しい ADR から置き換える判断を明記する。
