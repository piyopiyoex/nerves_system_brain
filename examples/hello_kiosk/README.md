# hello_kiosk

`nerves_system_brain` 用の、SHARP **Brain PW-SH6** で動作確認済み Elixir KIOSK 例。
Mix アプリ名と release 名は既存環境との互換性のため `hello_kiosk_brain` のまま維持する。

- SoC: NXP i.MX283（ARM926EJ-S / ARMv5TEJ soft-float / RAM 128MiB）
- LCD: 5.5インチ 854×480（RGB565 LE, /dev/fb0 直描画）
- ネットワーク: USB-NCM ガジェット（母艦 10.42.0.1 ⇔ Brain 10.42.0.2）
- ランタイム: OTP 29 + Elixir 1.20（ERTS 非同梱リリース、バイトコードは母艦でビルド）
- システム: [nerves_system_brain](../..)（nerves_system_br ベース、
  カーネル/U-Boot は brain-hackers 資産を流用）

実機で KIOSK デモ（**LovyanGFX 日本語 UI**・タッチ・キーボード・電池表示・時計・下部バー7ボタン・電源ボタン/電源OFF確認）+ SSH（IEx / リモート評価 / SFTP）稼働中。
調査結果: 起動時タッチ遅延（SSH crypto 初期化が主因＝**解消済**）／バックライト（LCD 電源と一体で**独立制御不可**と実機確定）／音声（オンボード codec は回路情報の壁で凍結し **USB オーディオを本命**に）／電源OFF（5V 接続中は i.MX28 シリコン仕様で電源断維持不可＝再起動になる）。

## 画面（実機の /dev/fb0 をダンプした実スクリーンショット）

下部タブ（タッチ）またはキー 1/2/3/4 で 4 画面を切り替える。
描画は LovyanGFX NIF（`priv/kiosk_nif.so`、efont/IPA 日本語ゴシック）。
ヘッダ共通: タイトル / 日時（JST、毎秒更新）/ 電池（LRADC 実測、充電中は+緑）/ IP。

| ホーム | タッチ |
|---|---|
| ![ホーム](docs/img/kiosk_home_ja.png) | ![タッチ](docs/img/kiosk_touch_ja.png) |

| キー | デモ |
|---|---|
| ![キー](docs/img/kiosk_keys_ja.png) | ![デモ](docs/img/kiosk_demo_ja.png) |

- **ホーム**: 稼働秒数とサブシステム状態の一覧。「メモリ」は **`使用量 / 総量 MB`**（左＝使用量 `MemTotal-MemAvailable`、右＝総 RAM `MemTotal`。128MiB 機で約 112MB 総量。例 `38 / 112 MB` は使用 38MB・空き約 74MB）
- **タッチ**: タップ位置に点を描画、座標表示（タッチは実機校正 + Y 反転）
- **キー**: 押されたキーのコード表示
- **デモ**: LovyanGFX MovingIcons（スプライト 50 個 11fps）。タッチ/キーでホームへ

## セットアップ（クローン後）

先にリポジトリルートで `nerves_system_brain` をビルドして `o/` を作成する。
その後、このディレクトリで実機用 release を構築する。

Erlang / Elixir のバージョンは `.tool-versions` で固定しているため、mise と asdf の
どちらでも利用できる。使用するツールマネージャーで事前にインストールする。

```sh
mise install   # または: asdf install

./scripts/setup_ssh.sh       # SSH ホスト鍵 + authorized_keys を生成（git 管理外）
./scripts/build_release.sh   # ARMv5 NIF をクロスコンパイル + ERTS-less release を構築
```

`MIX_ENV=prod mix release` だけでは、ARMv5 用 `kiosk_nif.so` のクロスコンパイルと
ターゲット OTP アプリの取り込みを行わないため、PW-SH6 へ配備する release の構築には
`build_release.sh` を使用する。

既定では [`nerves_system_brain`](../..) の `o/` を参照する。別のシステムリポジトリや
Buildroot 出力を使う場合は次のように指定できる。

```sh
NERVES_SYSTEM_BRAIN_DIR=/path/to/nerves_system_brain ./scripts/build_release.sh
NERVES_BUILD_DIR=/path/to/build-output ./scripts/build_release.sh
```

SD の作成・初回配備はリポジトリルートの `sd/` 以下を使用する。

> **SSH / crng**: 初期実装では起動直後の乱数初期化と SSH crypto 処理が UI を
> 長時間ブロックする問題があった。現在は SSH の遅延起動・モジュール分散ロード・
> 軽量なパスワード検証で回避している。調査経緯は
> [docs/20260903_SSH起動不能_セカンドオピニオン質問書.md](docs/20260903_SSH起動不能_セカンドオピニオン質問書.md) 参照。

## 開発サイクル（SD 往復不要）

```sh
./scripts/build_release.sh     # リリース構築（staging から armv5 OTP アプリを合流）
# 変更 beam を sftp で /srv/erlang/lib/hello_kiosk_brain-*/ebin へ put
ssh user@10.42.0.2 ':code.purge(Mod); :code.load_file(Mod); GenServer.stop(HelloKioskBrain.Display)'
./scripts/screenshot.sh        # 実機 LCD をリモートで PNG 取得
./scripts/settime.sh           # 母艦の時刻を Brain に設定(RTC 非搭載のため毎ブート後に)
```

> 実機に電池バックアップ付き RTC は無く(/dev/rtc0 も無し)、時計は毎ブート
> 1970 年起点に戻る。KIOSK ヘッダの時計は未設定時「時刻未設定」表示になるので、
> ブート後に `settime.sh` で合わせる。

初回の SD 作成・配置はリポジトリルートの `sd/`（populate_sd.sh → deploy_release.sh）。

## モジュール構成

| モジュール | 役割 |
|---|---|
| `HelloKioskBrain.Native` | LovyanGFX 描画 NIF ローダ（init_display / render / MovingIcons）。hello_kiosk_papapa と同一構成 |
| `HelloKioskBrain.Draw` | 描画コマンド DSL（clear/rect/line/circle/text…、日本語 jp8〜jp40）。NIF 非依存の純粋関数 |
| `HelloKioskBrain.Kiosk` | KIOSK デモ GUI（下部バー7ボタン=ホーム/タッチ/キー/デモ/予備1/予備2/電源を切る、物理キー15/104/109/110/111 と対応、電池/IP/時計、電源OFF確認）。LovyanGFX NIF 描画 |
| `HelloKioskBrain.Backlight` | LCD バックライト sysfs ラッパ（現状**未使用**。PW-SH6 はバックライトを独立制御できないと実機で判明。[調査結論](docs/20260904_バックライト制御線_調査結論.md)参照） |
| `HelloKioskBrain.Fb` | 旧・シャドウフレーム描画（フォールバックとして残置） |
| `HelloKioskBrain.Font` | 旧・5×7 ビットマップフォント（Fb 用、残置） |
| `HelloKioskBrain.Input` | evdev 読取り（タッチ event1 / キー event0）。タッチは実機校正 + Y 反転済み |
| `HelloKioskBrain.Battery` | i.MX28 HW_POWER から電池電圧/充電状態（devmem 経由） |
| `HelloKioskBrain.Display` | 旧・最小 KIOSK 画面（Kiosk に置換、参考として残置） |
| `HelloKioskBrain.SshDaemon` | OTP `:ssh`（公開鍵認証 + IEx + direct exec + SFTP、crng 非ブロッキング起動） |

補助バイナリ（`priv/bin/`、ソースは `src/`）: `devmem`（/dev/mem mmap R/W）。

## ドキュメント

`docs/` 配下。日付順・カテゴリ別。★=最新/現行の論点。

### 構築・実装(完了)
- [構築方法提案書（計画と進捗ステータス）](docs/20260831_構築方法提案書.md)
- [Phase 0-1 実機検証作業報告書](docs/20260902_Phase0-1_実機検証作業報告書.md)
- [Phase 2-4 Nerves化実装報告書（実装仕様・ハマりどころ・残タスク）](docs/20260902_Phase2-4_Nerves化実装報告書.md)
- [母艦-Brain 接続手順書（日常運用・トラブルシュート）](docs/20260902_母艦_Brain_接続手順書.md)
- [作業引き継ぎ書（2026-09-03 時点の全体像）](docs/20260903_作業引き継ぎ書.md)

### 描画: LovyanGFX 日本語 UI(完了・実機動作)
- [LovyanGFX 導入計画書](docs/20260904_LovyanGFX導入計画書.md)
- [Phase 0 + NIF 移植報告書](docs/20260904_LovyanGFX_Phase0_NIF移植報告書.md)
- [Phase 2 KIOSK 日本語 UI 報告書](docs/20260904_LovyanGFX_Phase2_KIOSK日本語UI報告書.md)

### 音声・タッチ音(方針転換: USB オーディオを本命に)
- ★[音声方針転換: USB オーディオを本命に（オンボード codec は凍結）](docs/20260905_音声方針転換_USBオーディオ.md)
- [KIOSKデモ完成 + タッチ音 初期調査記録](docs/20260904_KIOSKデモ完成_タッチ音調査記録.md)
- [タッチ音(PWM ブザー)調査 結論](docs/20260904_タッチ音_PWM調査結論.md)
- [音声 SGTL5000 セカンドオピニオン質問書（版1-4 の往復記録）](docs/20260904_音声SGTL5000_セカンドオピニオン質問書.md)
- [音声調査 結論: DTBと実機I2C不一致（SGTL5000@0x0a は不在）](docs/20260904_音声調査結論_DTBと実機I2C不一致.md)
- [音声 0x1aコーデック同定 作業報告兼質問書（NAU8822 否定寄り／read プロトコル異常・ソフト同定は限界）](docs/20260904_音声0x1aコーデック同定_作業報告兼質問書.md)

### バックライト・起動時タッチ遅延(調査完了)
- [バックライト制御線 調査結論（PW-SH6 は独立制御不可・LCD 一体）](docs/20260904_バックライト制御線_調査結論.md)
- [起動時タッチ遅延 調査（真因=SSH crypto、SSH 起動遅延で解消）](docs/20260904_起動時タッチ遅延_調査.md)

### 電源(調査完了)
- ★[電源 ON/OFF・スタンバイ 調査報告](docs/20260904_電源ONOFF_スタンバイ調査.md)
- [電源OFF(5V接続中) 調査結論（i.MX28 は 5V 存在中に電源断を維持できない＝シリコン仕様）](docs/20260905_電源OFF_5V接続中_調査結論.md)

### SSH / ネットワーク・OTA(提案・保留)
- [SSH起動不能 セカンドオピニオン質問書（crng 初期化・SSH 起動調査の経緯）](docs/20260903_SSH起動不能_セカンドオピニオン質問書.md)
- [有線LAN化 USBホスト 提案書](docs/20260903_有線LAN化_USBホスト_提案書.md)
- [Phase0 USBホスト有線LAN 実機検証手順書](docs/20260903_Phase0_USBホスト有線LAN_実機検証手順書.md)
- [OTA導入 / USBガジェット停止 提案書](docs/20260903_OTA導入_USBガジェット停止_提案書.md)
