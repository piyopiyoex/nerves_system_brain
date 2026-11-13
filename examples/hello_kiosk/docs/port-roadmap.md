# hello_kiosk feature port ロードマップ

最終更新: 2026-11-13 / 対象: `feat/port-hello-kiosk-brain-features`（WIP）

## 目的と完了条件

`kurokouji/hello_kiosk_brain`（2026-11-13 受領スナップショット）の機能を、
`nerves_system_brain/examples/hello_kiosk` へ取り込み、SHARP Brain PW-SH6 で安全に使える状態にする。
**コードの移植と動作確認は別工程**とする。元アプリと完全に同じ実装や、
未対応ハードウェア機能までの同時移植は目標にしない。

完了と呼べる条件は、少なくとも次のとおり。

- host の compile/test と `MIX_TARGET=brain mix firmware` が成功し、結果を記録している。
- PW-SH6 で起動、タッチ/キー、デモ、カメラの復帰、USB HOST/NCM、SSH を確認している。
- 既存の A/B 更新と永続データの動作を回帰テストしている。
- 対応できた機能と、周辺機器・追加 kernel/DTB・素材が必要な機能を区別している。
- 充電制御など安全性に関わる機能を、検証前に既定で有効化しない。
- 同梱する第三者データ/音声の権利を確認し、必要な notice を保持する。

## 現在地

**2026-11-13 時点: WIP / static review 済み / build・実機テスト未実施。**
既存の port patch は `examples/hello_kiosk` に機能を追加した段階であり、
この roadmap のチェックは **この先の受け入れ確認** を表す。

状態の表記: `実装済・未検証` = コードはあるが実機で動いた証拠がない、
`維持・回帰待ち` = 移植前の既存機能、`保留` = 依存条件未達。担当者と期限は未割当。

| 領域 | 現状 | 優先度 | 次に確認すること |
|---|---|---|---|
| Kiosk ナビゲーション/設定画面 | 実装済・未検証 | P0 | 入力、画面遷移、表示の固まり |
| 描画・9 デモカード（音声素材のないデモを含む） | 実装済・未検証 | P0/P1 | 描画コマンド、終了操作、速度/メモリ |
| ネットワークカメラ | 維持・回帰待ち | P0 | framebuffer 所有権と復帰 |
| SSH / USB HOST・NCM / A/B 更新 | 維持・回帰待ち | P0 | 起動・復旧・永続化 |
| Wi-Fi 設定 UI / VintageNet adapter | 実装済・未検証 | P1 | 保存、接続確認、失敗時 rollback |
| 手書きメモ / 永続設定 | 実装済・未検証 | P1 | ペン座標、保存、再起動後復元 |
| Battery / RTC / 電源診断 | 実装済・未検証 | P1 | 測定値、起動時の競合、誤書込 |
| USB 音声 / BLE / SwitchBot | 実装済・未検証 | P2 | 対応デバイス・ドライバ・音声素材 |
| 充電制御 | 保留・既定無効 | 別判断 | 電池安全レビューと制御の実測 |
| PWM バックライト / BU26154 内蔵音声 | 保留 | 別判断 | DTB/kernel/回路の根拠と ADR 再評価 |

## フェーズと受け入れ基準

### P0 — ビルドと既存動作の保護（最優先）

- [ ] `MIX_TARGET=host mix deps.get` と `MIX_TARGET=host mix test` が通る。必要なら NullBackend で描画を検査。
- [ ] `MIX_TARGET=brain mix firmware` が通る（System/toolchain が準備できていること）。
- [ ] `Input`・`Draw`・`WifiConfig` の host 単体テストを追加する。特に描画 command の互換性と Wi-Fi の失敗経路。
- [ ] テスト用 microSD で PW-SH6 が起動し、Kiosk が表示され、NervesSSH/IEx が使える。
- [ ] ホーム/タッチ・キー/デモ/設定/電源メニューを操作できる。無操作時にも UI が固まらない。
- [ ] カメラを開始→停止→通常画面へ復帰し、再入場しても LCD が破綻しない。
- [ ] USB HOST と NCM を切り替え、切り替え後に期待する通信経路を使える。
- [ ] 既存 A/B `mix upload` と正常起動時の確定、persistent `/data` の維持を回帰確認する。
- [ ] SSH が利用できないときの復旧手段（microSD/ローカル入力）を実機テスト前に確保する。

**P0 完了の定義:** 新しい UI を起動でき、旧機能（通信/カメラ/更新）を壊していないことを実機記録で示す。

### P1 — 新しい Kiosk 機能の安定化

- [ ] MovingIcons、フライト、花火、世界時計、プラネタリウム、手書きメモを個別に確認する。
- [ ] 画面切替、タッチペンの `down/move/up`、キー操作、デモ終了後の再描画を検証する。
- [ ] `memo_strokes.bin` と `kiosk_settings.term` の保存/再起動後の読み込みを確認する。
- [ ] 空ファイル・不完全な保存データ・容量不足で起動が止まらないことを確認する。
- [ ] Wi-Fi の追加/編集/削除、パスワード非表示、切断時の rollback、再起動後の持続を検証する。
- [ ] Wi-Fi 機器なしで保存した profile は「未接続/未検証」として扱われることを確認する。
- [ ] Battery の電圧/5V 判定とログ、`BrainClock` の RTC 読み書きを対象実機で照合する。
- [ ] System の `restore_brain_rtc` と `BrainClock` が時刻を競合更新しないことを検証する。
- [ ] スクリーンショットを新 UI で撮り直し、README の旧画面と差し替える。

**P1 完了の定義:** 非音声デモと基本設定が安定動作し、起動・再起動をまたぐ状態保持を説明できる。

### P2 — 周辺機器と素材が必要な機能

- [ ] USB HOST + セルフパワーハブで接続する音声デバイスを決め、再生/録音/音量を確認する。
- [ ] Bluetooth adapter の driver/firmware と BlueZ/BlueALSA の動作を確認する。
- [ ] SwitchBot BLE scan の権限、検出結果、異常時の動作を確認する。
- [ ] 時計読み上げ/音声デモ/花火効果音/二重唱用の素材をライセンス確認のうえ調達・生成する。
- [ ] 素材なしの場合の UI（利用不可表示、無音での実行/終了）を確認する。
- [ ] CPU・RAM・起動時間・描画遅延を計測し、PW-SH6 の 128MiB 制約内で許容できることを確認する。

**P2 完了の定義:** 実施したデバイス構成と素材の出典を明記し、「何が必要なら動くか」を再現可能にする。

### 別トラック — ハードウェア変更と安全性

- **充電制御:** `enable_charger: false` を維持。セル/温度/停止条件/過充電防止策の安全レビューと
  計測手順が整うまでは有効化しない。機能の採用自体を別 issue / ADR で判断する。
- **バックライト:** 既存 [ADR 0003](adr/0003-バックライト制御線_調査結論.md) は「独立制御しない」。
  移植した `Backlight` API があることは PWM 調光の実証ではない。DTB と配線を検証してから判断する。
- **内蔵 BU26154:** ソース由来の音声分岐はあるが、現行 kernel/DTB に対応 driver があるとは限らない。
  既存 [ADR 0004](adr/0004-音声_DTBと実機I2C不一致.md) と
  [ADR 0006](adr/0006-USBオーディオを採用する.md) の前提を、別途根拠をもって再評価する。
- **配布物:** [`NOTICE.original-demos`](../NOTICE.original-demos) を確認する。
  `priv/demo/*.term` の派生元の notice は同梱し、音源は個別の再配布可否を確認する。

これらは P0/P1 の前提条件ではない。機能を有効化する PR と、安全性を検証する PR は分ける。

## 実機テストの進め方

まず [初回セットアップ](../../../docs/getting-started.md) と
[firmware 更新手順](../../../docs/mix-upload.md) を読む。
**`mix burn` は p4 の永続データも初期化する**ため、既存カードを消さずに試すなら
適切にバックアップしたうえで `mix upload` を使う。boot assets / DTB の更新には新規 microSD を使う。

```sh
# リポジトリルート: 初回だけ System のビルド
mix brain.system.build

cd examples/hello_kiosk
MIX_TARGET=host mix deps.get
LOVYANGFX_ELIXIR_SKIP_NATIVE=1 MIX_TARGET=host mix test

export MIX_TARGET=brain
mix deps.get
mix firmware
# テスト用 microSD を初期化する場合だけ: mix burn
# 既存の A/B 配置を利用する場合: mix upload nerves.local
```

実機の順序: **表示・入力 → SSH → USB モード → カメラ → 新規デモ → 設定保存 → Wi-Fi → 外部音声/BLE**。
Wi-Fi の編集は接続を切断し得るため、最初は USB または別の復旧経路を確保して行う。
NCM と USB HOST は同一 USB ポートで同時には使えない。

### 実験結果の記録テンプレート

`docs/worklog/` に日付付きファイルで追加する。成功した項目だけチェックし、未確認はそのまま残す。

```text
# YYYYMMDD feature-port 検証
- git revision / firmware hash:
- PW-SH6 個体 / microSD / 電源構成:
- USB mode / 使用したアダプタ / display・DTB:
- 確認手順:
- 期待結果 / 実際の結果:
- NervesSSH・IEx・ログ・写真などの根拠:
- 再現手順 / 回避策 / 次の担当(issue):
```

## 開発者間の進め方

1. 作業前に [移植差分の記録](feature-port-20261113.md) と関係する ADR を読む。
2. 上表の未確認項目を issue に切り出し、**担当・検証機材・完了条件**を issue 上で合意する。
3. PR では「コード追加」「host テスト」「PW-SH6 実機確認」を別々に記載する。
4. 実機で確認したら worklog に結果を残し、この roadmap の該当欄を更新する。
5. カーネル/DTB、FW 更新方式、音声経路など採用判断を変える場合は ADR を新設する。

**範囲外:** private source の丸ごと公開、旧 `SshDaemon` / 独自 Wi-Fi daemon 管理の復活、
古い release/SFTP 展開方式への回帰。System 側を変更する必要が出たら example とは別 PR にする。
