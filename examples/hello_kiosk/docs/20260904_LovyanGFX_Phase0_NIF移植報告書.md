# LovyanGFX Phase 0 通過 + papapa 構成の NIF 移植 報告書

- 日付: 2026-09-04
- プロジェクト: hello_kiosk_brain(SHARP Brain PW-SH6)
- 前提: [20260904_LovyanGFX導入計画書.md](20260904_LovyanGFX導入計画書.md)
- 結論: **Phase 0(実機で LovyanGFX 描画・日本語・色順)通過**。統合方式は計画書の
  推奨 A(Port)ではなく **B(NIF)を採用** — hello_kiosk_papapa の実績構成を
  そのまま流用できたため。

---

## 1. 方式決定: Port(計画書推奨)→ NIF(papapa 構成流用)に変更

計画書 §2.2 では「A. Port(別プロセス)」を本命としていたが、実装は
**hello_kiosk_papapa で実績のある NIF 構成をほぼそのまま移植**した。

- 理由: papapa で同じ LovyanGFX NIF(kiosk_nif)が完動しており、
  Makefile / C++ ソース / Elixir ラッパを流用すれば新規設計ゼロで済む。
  Port プロトコル設計・プロセス管理の工数を丸ごと省ける。
- papapa との差分(意図した2点のみ):
  - `SCREEN_X 854`(papapa は 800。本機は 854×480)
  - モジュール名前空間 `HelloKioskBrain.*`(papapa は `HelloKiosk.*`)
  - `kiosk_draw.hpp` / `icons.cpp` は **バイト単位で同一**
- NIF クラッシュ = BEAM ごと落ちるリスクは papapa 実績で許容と判断。
  問題が出たら計画書の Port 案に戻す(UI 状態は Elixir 側にあるので移行可能)。

## 2. 構成ファイル

| ファイル | 役割 |
|---|---|
| `Makefile` | LovyanGFX を clone し `LGFX_LINUX_FB` + efont/IPA 日本語フォント込みで NIF をビルド(papapa と同一) |
| `c_src/kiosk_nif.cpp` | NIF 本体: init_display / render(コマンド列) / start・stop_moving_icons |
| `c_src/kiosk_draw.hpp` | 描画コマンドのディスパッチ(text/rect/fill/line/circle…、jp8〜jp40 フォント) |
| `c_src/icons.cpp` | Moving Icons デモ(背景スレッド) |
| `c_src/gfx_test.cpp` | Phase 0 用スタンドアロン検証(efont ja16 でメモリ描画 → pwrite) |
| `lib/.../native.ex` | `@on_load` NIF ローダ |
| `lib/.../draw.ex` | Elixir 側描画コマンド DSL(iodata 組立て) |
| `lib/.../gfx_demo.ex` | 起動時検証 GenServer: fbcon unbind → 日本語1フレーム → Moving Icons |
| `lib/.../icons.ex` | アイコン定義 |

- ビルド: Bootlin armv5 ツールチェーン(gcc 14.3.0)で手動 make。
  `CROSSCOMPILE=/home/owner/toolchains/armv5-eabi--glibc--stable-2025.08-1/bin/arm-linux MIX_APP_PATH=_build/prod/lib/hello_kiosk_brain make`
  (`_build/.../priv` はソース `priv/` への symlink なので成果物は `priv/kiosk_nif.so` に出る)
- 成果物サイズ **約 44MB** は efont(ja/cn/kr/tw)+ IPA 全同梱によるもので
  **papapa と同じ**(papapa の .so も 44MB)。SD 運用では許容。
  絞るなら Makefile の Fonts wildcard を ja のみに削る余地あり(未実施)。
- `.gitignore`: papapa に合わせ `/priv/*.so` と `/c_src/LovyanGFX/` を除外
  (どちらも Makefile で再生成可能)。

## 3. Phase 0 実機検証(通過)

- 証拠: [img/lovyangfx_ja_phase0.png](img/lovyangfx_ja_phase0.png)(実機 fb0 キャプチャ)
- 確認内容:
  - **日本語描画 OK**(「日本語テスト: シャープ ブレイン」efont/IPA)
  - 英数テキスト・塗り矩形・円 OK
  - **RGB565 色順 OK**(緑矩形が緑、赤円が赤、紺背景 — kiosk_7inch で踏んだ
    バイトスワップ問題は再発せず)
- 計画書 §2.1 の懸念「ARMv5 soft-float で C++/LovyanGFX がビルドできるか」は
  **解消**。Bootlin ツールチェーンでビルド・実機動作とも問題なし。

## 4. application.ex の一時構成(検証用)

NIF 検証中は自作 Fb(Kiosk)と fb0 が競合するため、children を
`SshDaemon + GfxDemo` のみに変更中(Battery / Input / Kiosk は一時停止)。
**Phase 2(Kiosk 描画の NIF 移行)完了時に正式構成へ戻す。**

## 5. 最新ビルドの実機検証(12:19 追記・完了)

Phase 0 スクショ(11:28)取得後に c_src を papapa 同一版へ揃えて再ビルドした
最新 .so(11:35, md5 5ab9124d…)について、実機で以下を確認した。

- 実機配備済み .so の md5 がローカル最新ビルドと**一致**(SSH で実測)。
- Supervisor children = `GfxDemo + SshDaemon`(検証構成どおり)。
- **Moving Icons デモ実機動作 OK**: 画面キャプチャ
  [img/lovyangfx_moving_icons.png](img/lovyangfx_moving_icons.png)。
  スプライト 50 個 + アルファ合成で **fps 11**(画面左上 `obj:50 fps:11`)。
  日本語オーバーレイ(「MovingIcons 実行中」「タッチでホームへ戻る」)も描画良好。
- 2回キャプチャで画像差分あり = アニメーション進行中を確認。

補足(母艦側): Brain を挿す USB ポートが変わると I/F 名が変わり接続断になるため、
NetworkManager の `brain-usb` プロファイルを `match.interface-name enp0s20f0u*`
(ポート非依存)に変更した。

## 6. 残作業

1. Phase 2: Kiosk の描画を Fb → Native/Draw に移行し、正式構成
   (Battery + Input + Kiosk + SshDaemon)へ復帰。日本語 UI 化。
2. Phase 3: 性能計測(render 1フレームの実測。自作 Fb は draw 201ms + flush 60ms が基準。
   Moving Icons 全画面 50 スプライトで 11fps ≒ 90ms/フレームは良い材料)。
