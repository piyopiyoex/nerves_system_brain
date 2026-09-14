# LovyanGFX 導入計画書

> **Worklog**: この文書は作成時点の調査・作業記録です。現在の判断は [`../README.md`](../README.md) と [`../adr/`](../adr/) を優先してください。

- 日付: 2026-09-04
- プロジェクト: hello_kiosk_brain（SHARP Brain PW-SH6）
- 目的: 自作の最小描画（5×7 ビットマップフォント）を **LovyanGFX** に置き換え、
  KIOSK の表示品質（フォント・日本語・図形・スプライト）を実用水準に引き上げる
- 位置づけ: 当初提案書では「LovyanGFX を移植せず薄い自作描画 API で」とした
  （工数回避）が、KIOSK デモが完動しシャドウフレーム描画の性能特性も判明した今、
  表示品質の底上げのために LovyanGFX 導入を再検討する

---

## 1. 背景

### 現状（自作 Fb）
- `HelloKioskBrain.Fb`: シャドウフレーム（行バイナリの map）に描画し、flush で
  **全画面を1回の pwrite** で /dev/fb0 へ（854×480, RGB565 LE, stride 1708）。
- フォントは自作 **5×7 ビットマップ**（英数記号のみ）。日本語・アンチエイリアス・
  多様なサイズ・図形（円・線・グラデ）は無い。
- 性能（実機実測 2026-09-04）: メモリ描画 ~200ms + flush ~60ms/画面。KIOSK には十分。

### 限界
- 日本語表示ができない（電子辞書の UI としては致命的）。
- フォントの種類・字形・可変サイズが乏しい。
- 図形描画・スプライト・画像表示が無い。

### LovyanGFX を選ぶ理由
- 多書体・**日本語フォント**（IPA/美咲フォント等）、任意サイズ、アンチエイリアス。
- 図形（線・矩形・円・角丸・グラデ）、スプライト（オフスクリーン）、画像（PNG/JPG/BMP）。
- **過去プロジェクト（hello_kiosk_7inch / raspad3）で LovyanGFX 実績あり** → 資産流用可。
- スプライト（内部バッファ）に描いて一括転送する使い方が、本機の
  「**全画面1回書き込みが速い**」という braindrmfb の特性と噛み合う。

## 2. 技術的課題（先に潰す論点）

### 2.1 ARMv5 soft-float での C++ ビルド【要確認だが見込みあり】
- LovyanGFX は C++11 以上。**Bootlin armv5 glibc ツールチェーン**
  （`/home/owner/toolchains/armv5-eabi--glibc--stable-2025.08-1`、gcc 14.3.0）で
  クロスビルドする。devmem/lns/rngseed の C 実績があり、C++ も同ツールチェーンで可能。
- LovyanGFX は元来 ESP32/Arduino 向けだが、**Linux フレームバッファ / SDL の
  バックエンド**を持つ（`LGFX_LINUX_FB` 系）。これをベースに Brain 用パネル
  バックエンドを作る。

### 2.2 Elixir/Nerves との統合方式【最重要の設計判断】
LovyanGFX は C++。Elixir から使う方式は3つ:

| 方式 | 概要 | 評価 |
|---|---|---|
| **A. Port（外部プロセス）** | LovyanGFX を使う C++ 実行ファイルを Port で起動。Elixir から描画コマンドを送る | **本命**。クラッシュが BEAM に波及しない。kiosk_7inch の実績方式に近い |
| B. NIF | LovyanGFX を NIF 化して直接呼ぶ | 高速だが NIF クラッシュで BEAM ごと落ちる。ARMv5 での安定性リスク |
| C. C++ 側で全 UI | 描画も入力も C++ に寄せ、Elixir は最小 | Nerves/OTP の利点を捨てる。非推奨 |

推奨: **A（Port）**。Elixir 側が UI ロジック・状態・入力（既存の Input/Kiosk）を持ち、
C++ 側（LovyanGFX）は「描画コマンドを受けて fb に出す描画サーバ」に徹する。

### 2.3 fb への書き込み方式【今日の知見を反映】
- braindrmfb は **小さい書き込みの乱発が激遅、全画面1回書き込みが速い**
  （2026-09-04 実測: 自作 Fb でこれを回避してシャドウ+flush にした）。
- LovyanGFX でも同様に、**オフスクリーンのスプライト（854×480 RGB565）に描画 →
  完成フレームを1回で /dev/fb0 へ pwrite** する構成にする。
- LovyanGFX 標準の Linux fb バックエンドは mmap で直接描く実装が多いが、
  **braindrmfb で mmap が期待通りパネルへ反映されるかは未確認**。
  安全策として「LovyanGFX はメモリバッファに描き、転送だけ自前の pwrite」にする
  （= 自作 Fb の flush と同じ経路を C++ 側に持たせる）。

### 2.4 実機パラメータ（既知・確定）
- 解像度 854×480、16bpp RGB565 **リトルエンディアン**、stride 1708（パディングなし）。
- **色バイト順の落とし穴**（kiosk_7inch の教訓）: RGB565 のエンディアン/スワップを
  実機で必ず確認。LovyanGFX の color depth / byte swap 設定を実機で校正。

## 3. アーキテクチャ（推奨: Port 描画サーバ）

```
Elixir / Nerves (BEAM)
  Kiosk(UI状態) / Input(evdev)
        │ 描画コマンド(Port)
        ▼
  HelloKioskBrain.Gfx (Port ラッパ GenServer)
        │ stdin/stdout (バイナリプロトコル)
        ▼
brain_gfx (C++ / LovyanGFX)
  オフスクリーン Sprite(854x480)
   ├ text/日本語, 図形, 画像
   └ flush: 全画面を1回 pwrite -> /dev/fb0
```

- **プロトコル例**（1コマンド1行 or 長さ前置きバイナリ）:
  `CLEAR <rgb>` / `TEXT <x> <y> <size> <rgb> <utf8...>` / `RECT ...` /
  `FILL ...` / `IMAGE <x> <y> <len><bytes>` / `FLUSH`
- Elixir 側は既存 Kiosk のレイアウトロジックを活かし、描画呼び出しだけ
  Fb → Gfx(Port) に差し替える。

## 4. 段階計画

| Phase | 内容 | 完了条件 |
|---|---|---|
| **0. C++ ビルド検証** | Bootlin armv5 で LovyanGFX 最小サンプル（メモリバッファに矩形＋テキスト）をクロスビルド → 実機で RGB565 バッファを pwrite で fb0 に出す | 実機に LovyanGFX 描画が1枚出る（色順も確認） |
| **1. 描画サーバ brain_gfx** | Port プロトコルを定義し CLEAR/TEXT/RECT/FILL/FLUSH を実装。日本語フォント同梱 | Elixir から Port 経由で任意テキスト・図形が出る |
| **2. Gfx ラッパ + Kiosk 移行** | `HelloKioskBrain.Gfx`（Port 管理 GenServer）を作り、Kiosk の描画を Fb → Gfx へ移行。Input/Battery はそのまま | KIOSK 3画面が LovyanGFX 描画で再現、日本語可 |
| **3. 品質・性能** | 部分更新/ダブルバッファ、転送最適化、フォント・レイアウト調整 | 実用的な応答性と見栄え |

**Phase 0 が分岐点**: 「ARMv5 で LovyanGFX がビルド・動作し、fb に正しい色で出るか」。
ここが通れば導入の技術リスクはほぼ解消する。

## 5. リスクと対策

| リスク | 影響 | 対策 |
|---|---|---|
| LovyanGFX が ARMv5 でビルド不可/不安定 | 計画停止 | Phase 0 で最小構成を先に検証。ダメなら軽量代替（stb_truetype で日本語のみ足す） |
| Port プロトコルのオーバーヘッド | 描画が遅い | 差分/バッチ描画、バイナリプロトコル、FLUSH は1フレーム1回 |
| braindrmfb で mmap が効かない | 直接描画不可 | LovyanGFX はメモリに描き、転送は自前 pwrite（自作 Fb の flush 経路を流用） |
| 色バイト順ずれ | 色が化ける | 実機で RGB565 エンディアンを校正（kiosk_7inch の教訓） |
| C++ 依存の肥大化 | rootfs 増 | brain_gfx を静的リンク単一バイナリに（priv/bin へ、lns/devmem と同様） |
| Port プロセスのクラッシュ | 描画停止 | GenServer で監視・再起動。UI 状態は Elixir 側が保持するので復帰可 |

## 6. 自作 Fb との関係

- 自作 `Fb`（シャドウフレーム）は**撤去せず残す**。導入は段階的で、Phase 2 完了までは
  Fb 版 KIOSK が動作基準（フォールバック）。
- 「全画面1回 pwrite で fb に出す」という**転送経路の知見は共通**なので、brain_gfx の
  flush 実装にそのまま活かす。

## 7. まとめ / 次アクション

- LovyanGFX 導入で日本語・多書体・図形・画像が使え、電子辞書 UI として実用水準に。
- 推奨構成は **Port 描画サーバ**（C++/LovyanGFX を別プロセス、Elixir が UI と入力を保持）。
- braindrmfb の性質に合わせ、**LovyanGFX はメモリに描き転送は自前 pwrite** とする。
- **次アクション = Phase 0**: Bootlin armv5 で LovyanGFX 最小サンプルをビルドし、
  実機 fb0 に正しい色で1枚出す。ここでハード/ツールチェーン適合を確定する。

## 8. 参考

- 実機描画パラメータ・性能: [20260904_KIOSKデモ完成_タッチ音調査記録.md](20260904_KIOSKデモ完成_タッチ音調査記録.md)
- 当初の描画方針（LovyanGFX 見送りの経緯）: [20260831_構築方法提案書.md](20260831_構築方法提案書.md)
- LovyanGFX 実績: hello_kiosk_7inch / hello_kiosk_raspad3
- クロスツールチェーン: `/home/owner/toolchains/armv5-eabi--glibc--stable-2025.08-1`
