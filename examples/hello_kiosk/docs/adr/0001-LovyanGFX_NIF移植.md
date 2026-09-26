# 0001: LovyanGFX の統合に NIF を採用する

## 状態

採用

2026-09-26 更新: NIF を採用する判断は維持し、KIOSK 固有の `kiosk_nif.so` は廃止した。
LovyanGFX の取得・build・NIF lifecycle と Brain 用 buffered RGB565 backend は
`lovyangfx_elixir` dependency に集約する。`HelloKioskBrain.Native` は package public API への
adapter、`HelloKioskBrain.Draw` は command tuple 変換だけを担当する。

## 背景

PW-SH6 の KIOSK 描画では、日本語フォントを含む LovyanGFX を ARMv5 上で利用したい。
当初は BEAM から別プロセスを呼ぶ Port 方式も検討したが、既存の
`hello_kiosk_papapa` には LovyanGFX NIF の動作実績があった。

## 決定

LovyanGFX は NIF として統合する。UI 状態と描画コマンドの生成は Elixir 側に置き、
native integration は再利用可能な `lovyangfx_elixir` package が担当する。

## 理由

- 既存実装をほぼそのまま再利用でき、Port 用のプロトコルやプロセス管理を新設しなくてよい。
- Bootlin ARMv5 ツールチェーンでビルドでき、PW-SH6 実機で日本語描画・RGB565・Moving Icons を確認した。
- 854×480 への画面サイズ調整以外は既存構成を大きく変えずに利用できる。

## 影響

- NIF のクラッシュは BEAM 全体へ影響するため、ネイティブコードの不具合には注意が必要。
- `lovyangfx_nif.so` はターゲット ARMv5 用にクロスコンパイルする必要がある。
- フォントを広く同梱するため NIF のサイズは大きい。必要になれば対象フォントを絞る余地がある。

## 再評価条件

NIF の安定性が問題になる、または描画処理を BEAM から障害分離する必要が生じた場合は、
Port 方式を再評価する。

## 関連記録

- [LovyanGFX 導入計画](../worklog/20260904_LovyanGFX導入計画書.md)
- [NIF 移植・実機検証の詳細](../worklog/20260904_LovyanGFX_NIF移植_検証記録.md)
- [KIOSK 日本語 UI 実装報告](../worklog/20260904_LovyanGFX_Phase2_KIOSK日本語UI報告書.md)
- [lovyangfx_elixir 集約・実機検証](../worklog/20260926_lovyangfx_elixir集約_実機検証.md)
