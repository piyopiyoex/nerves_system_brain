# hello_kiosk_brain からの機能移植（2026-11-13）

> **状態: WIP / ソース比較と静的チェックまで。** host の compile/test、firmware build、
> SHARP Brain PW-SH6 実機確認は未実施。今後の作業項目と受け入れ条件は
> **[port-roadmap.md](port-roadmap.md)** にまとめる。

## 何を比較したか

- 移植元: `kurokouji/hello_kiosk_brain`（2026-11-13 受領の private repository スナップショット）
- 移植先: `piyopiyoex/nerves_system_brain/examples/hello_kiosk`（同日受領のスナップショット）
- 対象: **example の Elixir application とデモ用データ**。System/kernel/DTB は変更しない。

目標は、元アプリで増えた機能を現行 Nerves application から使えるようにすること。
**旧アプリの構造を再現することではない。** 現行プロジェクトの `NervesPack` / `VintageNet` /
`NervesSSH`、`lovyangfx_elixir`、`KioskLauncher`、`CameraMonitor`、`UsbMode`、
A/B firmware update と `/data` を正本とする。

## 機能比較

「移植」は**コードを取り込んだ**という意味であり、実機での動作確認済みを意味しない。

| 領域 | 今回の扱い | 注意・未確認事項 |
|---|---|---|
| ホーム画面（5V、温度、電池、音声/BLE/ネットワーク状態） | 移植 | sysfs と PMU 実測値の照合が必要 |
| 7 ボタン UI、設定、音量、時計編集 | 移植 | 新 UI は実機未確認。過去のスクリーンショットは旧版 |
| タッチペンと手書きメモ | 移植 | `/data/hello_kiosk/memo_strokes.bin` へ保存 |
| フライト、花火、おしゃべり時計、世界時計、プラネタリウム | 移植 | `Draw` → LovyanGFX の command 互換性を検証する |
| パパパの二重唱と口のアニメーション | コード移植 | `priv/audio/papapa` 不在。音源が揃うまで利用不可 |
| USB 音声、録音、読み上げ、時報 | コード移植 | audio device・userspace tool・素材の準備が必要 |
| Bluetooth speaker / SwitchBot BLE | コード移植 | USB radio/firmware、BlueZ/BlueALSA の実機確認が必要 |
| i.MX28 RTC ⇄ Linux clock | 移植 | System の `restore_brain_rtc` と実機で競合確認 |
| Wi-Fi profile 設定と状態表示 | **VintageNet 向けに再実装** | 90 秒の接続確認、失敗時 rollback、profile 持続を検証 |
| 5 段階バックライト調整 | API 移植のみ | PWM と DTB の構成が必要。既存 ADR の判断は変更しない |
| 充電コントローラ | コード移植・**既定無効** | 電池安全レビューなしで有効化しない |
| 起動履歴・crash/poweroff 診断 | 移植 | 永続ログの保存先を `/data/hello_kiosk` に統一 |
| ネットワークカメラ | **移植先の既存機能を維持** | 9 番目のデモカードから起動。復帰の回帰テストが必要 |
| USB HOST/NCM と SSH | **移植先の既存機能を維持** | System helper と NervesSSH を使用 |
| BU26154 オンボード codec | 未移植 | カーネル/DTB/audio driver の作業が必要。現行 system では未保証 |

移植した主なモジュール: `Audio`、`Backlight`、`Battery`、`BootLog`、`BrainClock`、
`BtSpeaker`、`Charger`、`CrashLog`、`FireworksDemo`、`FlightDemo`、`Input`、
`LetterSpeaker`、`MemoDemo`、`Mixer`、`PapapaDemo`、`Power`、`Recorder`、
`StarDemo`、`SwitchBotScanner`、`TalkDemo`、`TimeSignal`、`TimeSpeaker`、
`Version`、`WorldDemo`、`Kiosk`。

移植先に合わせた実装: `WifiConfig`、`WifiWatch`、`Application`、`Draw`、
`config/target.exs`。元アプリ独自の `SshDaemon`、`UsbMode`、`IexHelpers`、
`Icons`、`wpa_supplicant.conf` を直接書き換える仕組み、daemon kill / USB reset を行う
Wi-Fi recovery は意図的に取り込まない。

## 移植先の責務を維持する理由

```text
examples/hello_kiosk          <- UI、デモ、音声、入力、アプリ設定
  |  LovyanGFX / VintageNet / NervesSSH / CameraMonitor
  v
nerves_system_brain           <- OS、USB mode、firmware A/B、persistent data
  v
brain-hackers boot assets     <- U-Boot、kernel、DTB（今回変更なし）
  v
SHARP Brain PW-SH6
```

- **描画:** 元アプリの描画処理を `HelloKioskBrain.Draw` 経由で `lovyangfx_elixir` に接続する。
  カメラ表示中は外部 `camera_viewer` が framebuffer を使うので Kiosk 側は再描画を止める。
- **ネットワーク:** Wi-Fi の設定と持続は VintageNet が担当する。`WifiWatch` は状態参照と
  VintageNet への再設定依頼だけを行い、Wi-Fi daemon や USB ポートを独自に再起動しない。
- **ストレージ:** System の p4 を `/root` へ mount し、`/data` から参照する。
  ログ・メモ・設定は `/data/hello_kiosk/`、Wi-Fi profile は VintageNet 側で保存する。
- **firmware:** 既存の `mix burn` / `mix upload`、A/B fallback、SSH 経路を移植時も維持する。
  この移植で System-level の boot asset を変更したわけではない。

## 更新時の注意点

**設定・メモ:** 元アプリの `/root/kiosk_settings.term` と `/root/memo_strokes.bin` は
**自動移行されない**。必要ならバックアップして、
`/data/hello_kiosk/kiosk_settings.term` と `/data/hello_kiosk/memo_strokes.bin` に
手動で移す（フォーマット互換性も検証する）。`mix burn` は p4 の内容を消す。

**Wi-Fi:** `/etc/wpa_supplicant.conf` の profile も自動移行されない。画面の editor または
`VintageNetWiFi.quick_configure/2` で再登録する。画面 editor は WPA2-PSK を対象とし、
パスワードは一覧に表示しない。編集中のパスワード欄を空にすると既存 PSK を引き継ぐ。
機器が存在するときは 90 秒以内の association と IPv4 確認後に保存し、失敗時は設定を戻す。
機器がない場合も profile は保存できるが、その時点で接続確認したことにはならない。
接続中の SSH が切れる可能性があるため復旧経路を確保して試す。

**電池と時計:** `Charger` は `config :hello_kiosk_brain, enable_charger: false` で起動しない。
`true` にしても充電の安全性が保証されるわけではない。`BrainClock` は `/root/devmem` を
使って i.MX28 RTC を直接読み書きするため、System 起動時の時刻復元との役割分担を実機で確認する。

**バックライトと音声:** `Backlight` API が存在しても、これまでの実機で独立調光が成立した
ことにはならない。BU26154 の control 名を扱う audio code が存在しても、現行の prebuilt
kernel/DTB が codec を利用できることにはならない。既存の
[ADR 0003](adr/0003-バックライト制御線_調査結論.md) /
[ADR 0004](adr/0004-音声_DTBと実機I2C不一致.md) /
[ADR 0006](adr/0006-USBオーディオを採用する.md) を参照する。

## デモ用素材と配布条件

- 同梱: `priv/demo/world.term`（Natural Earth）と `stars.term`（d3-celestial 由来）。
  出典と BSD-3-Clause notice は [`NOTICE.original-demos`](../NOTICE.original-demos) を参照。
- 未同梱: Open JTalk の voice WAV、二重唱 WAV/タイムラインなど、素材の権利確認が必要な音声。
  手元の正当に利用できる素材を example の `priv/audio/` 以下に用意してから firmware build する。
- 必要な主な構成: `priv/audio/{touch,key,startup}.wav`、`alpha/{A..Z}.wav`、
  `time/*.wav`、`fireworks/*.wav`、`papapa/{duet.wav,duet_timeline.term}`。
  二重唱のデモカードは必要な素材が揃うまで使えない。
- 生成用 `scripts/gen_*.{sh,py}` は存在するが、生成したファイルの再配布権を保証しない。
  特に編曲 MIDI 由来の伴奏、Open JTalk の音声モデル、それぞれの利用条件を確認する。

## 検証状況と次の一手

2026-11-13 時点ではソース比較と静的統合チェック、patch の適用確認のみ。
Elixir/Mix のテスト、ARMv5 firmware build、実機の入出力と更新の検証は未実施。
優先順、手順、完了条件、証拠の残し方は **[port-roadmap.md](port-roadmap.md)** を正本とする。
