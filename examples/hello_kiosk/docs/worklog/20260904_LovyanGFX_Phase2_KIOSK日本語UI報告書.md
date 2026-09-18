# LovyanGFX Phase 2 完了報告書: KIOSK 日本語 UI 化 + 正式構成復帰

> **Worklog**: この文書は作成時点の調査・作業記録です。現在の判断は [`../README.md`](../README.md) と [`../adr/`](../adr/) を優先してください。

- 日付: 2026-09-04
- プロジェクト: hello_kiosk_brain(SHARP Brain PW-SH6)
- 前提: [20260904_LovyanGFX_Phase0_NIF移植報告書.md](../adr/0001-LovyanGFX_NIF移植.md)
- 結論: **Kiosk の描画を自作 Fb → LovyanGFX NIF へ全面移行し、日本語 UI で
  正式構成(Battery + Input + SshDaemon + Kiosk)の実機動作を確認**。
  計画書の Phase 2 完了条件「KIOSK 3画面が LovyanGFX 描画で再現、日本語可」を達成。

---

## 1. 変更内容

### kiosk.ex(全面書換え)
- 描画: `Fb`(シャドウフレーム + 5×7 英数フォント)→ `Draw`(コマンド DSL)+
  `Native.render/1`(NIF が オフスクリーン描画 → fb0 一括転送)。
- UI 全面日本語化(efont/IPA ゴシック jp16〜jp32)。datum 指定(`:mc` 等)で
  中央揃えが 1 コマンドになり、旧版の text_width による手動センタリングを廃止。
- **デモタブを新設**(4 画面目): NIF の MovingIcons を起動し、タッチ/任意キーで
  ホームへ復帰(`stop_moving_icons` → 再描画)。NIF 側の案内文
  「タッチでホームへ戻る」と整合。
- キー割当: 1/2/3/4(コード 2/3/4/5)= ホーム/タッチ/キー/デモ。

### application.ex(正式構成復帰)
- children = `Battery, Input, SshDaemon, Kiosk`。
- SshDaemon を Kiosk より前に: NIF 描画(新規リスク)が起動失敗しても SSH を確保。
  Input は Kiosk.init の `Input.subscribe` より先に必要(従来どおり)。
- 検証用 GfxDemo は監視ツリーから除外(モジュールは手動検証用に残置)。

### 旧描画スタック
- `Fb` / `Font` / `Display` は削除せず残置(計画書 §6 のフォールバック方針)。

## 2. 実機検証(すべて確認済み)

検証は 2 段階で実施した。

### 2.1 ホットロード検証(再起動なし)
新 Kiosk.beam を SFTP → `:code.load_binary` → 稼働中スーパーバイザに
Battery/Input/Kiosk を `Supervisor.start_child` で追加。SSH から入力イベントを
シミュレート(`send(kiosk_pid, {:touch, x, y})` / `{:key, code, :down}`)し、
fb0 ダンプで全画面を確認:

| 画面 | 確認内容 | スクショ |
|---|---|---|
| ホーム | 日本語タイトル・稼働秒・電池 59% 3835mV・IP・状態一覧・タブ | [assets/kiosk_home_ja.png](assets/kiosk_home_ja.png) |
| タッチ | タブタップで遷移、座標表示、タップ位置に点 | [assets/kiosk_touch_ja.png](assets/kiosk_touch_ja.png) |
| キー | キーコード表示(コード 30 例)、キー 3 で遷移 | [assets/kiosk_keys_ja.png](assets/kiosk_keys_ja.png) |
| デモ | MovingIcons 起動(50 個 11fps)→ タッチでホーム復帰、稼働秒・電池は継続更新 | [assets/lovyangfx_moving_icons.png](assets/lovyangfx_moving_icons.png) |

### 2.2 正式構成ブート検証
- Kiosk.beam + Application.beam を `/srv/erlang/lib/hello_kiosk_brain-0.1.0/ebin/`
  へ SFTP(md5 照合)→ `/sbin/reboot`。
- 約 40 秒で USB-NCM 復帰(母艦 NM プロファイルのポート非依存化が機能)。
- **実機の目視でデモ良好・動作確認済み(ユーザー確認)**。

## 3. 知見

- **描画性能は KIOSK 用途に十分**: 全画面 1 フレーム描画(日本語テキスト十数個
  + 矩形群)が体感即時。MovingIcons(全画面 50 スプライト回転拡縮)でも 11fps。
- **NIF の mmap 直接転送は braindrmfb で問題なし**(計画書 §2.3 の懸念は解消。
  NIF 内で 2 バイトスワップしつつ mmap 領域へ書く方式で正しくパネルに出る)。
- **SSH からの入力イベントシミュレーションが有効**: `send(kiosk_pid, {:touch,…})`
  で実機に触らず全画面遷移を検証でき、スクショと組み合わせて回帰確認が容易。
- ホットロード(beam 差替え + `Supervisor.start_child`)で再起動なしに
  新 UI を検証できた。開発サイクルは「build_release → 変更 beam を SFTP →
  ホットロード → screenshot.sh」が最速。

## 4. 残作業(Phase 3 相当)

1. 性能計測の数値化(render 1 フレームの実測 ms。旧 Fb: draw 201ms + flush 60ms が基準)。
2. 部分更新・ちらつき対策が必要になったら検討(現状は全画面再描画で十分)。
3. 旧 Fb/Font/Display の撤去判断(安定運用を見てから)。
4. 電子辞書 UI 本体(検索・辞書表示)の設計 — LovyanGFX 化で日本語表示基盤は完成。
