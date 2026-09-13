# PW-SH6 Nerves 化 実装報告書（Phase 2〜4 コア完了）

- 日付: 2026-09-02
- プロジェクト: hello_kiosk_brain
- 対象実機: SHARP Brain PW-SH6（i.MX283 / ARMv5TEJ soft-float / RAM 128MiB / LCD 854×480）
- 前編: [20260902_Phase0-1_実機検証作業報告書.md](20260902_Phase0-1_実機検証作業報告書.md)
- 関連: [20260831_構築方法提案書.md](20260831_構築方法提案書.md) /
  [20260902_母艦_Brain_接続手順書.md](20260902_母艦_Brain_接続手順書.md)

---

## 1. 結論

**電子辞書 PW-SH6 が Nerves デバイスになった。** リセット一発で
`BootROM → U-Boot → linux-brain → Nerves rootfs(ext4) → erlinit(PID1) →
hello_kiosk_brain リリース(OTP 29 / Elixir 1.20)` が起動し、LCD に KIOSK 画面を表示、
USB-NCM 経由で母艦から SSH 到達できる。

さらに **SD 往復も本体操作も不要な完全リモート開発サイクル**を確立した:

```
コード修正 → scripts/build_release.sh → SFTP 転送
 → ssh でホットリロード(再起動なし) → scripts/screenshot.sh で画面確認
```

## 2. 成果物

| 場所 | 内容 |
|---|---|
| `~/my_nerves_examples/nerves_system_brain/` | カスタム Nerves システム。nerves_defconfig（arm926t / Bootlin armv5 glibc / ext4 / カーネル非ビルド）、rootfs_overlay（erlinit.config / enable_ethernet_gadget v2 / lns）、VERSION |
| `nerves_system_brain/sd/` | SD 組み立て・更新スクリプト群（populate_sd.sh / deploy_release.sh / update_gadget_v2.sh）、**デバイスモード有効化パッチ済み DTB**（imx28-pwsh6-peripheral.dtb）、動作実績 DTB・診断ログ |
| `hello_kiosk_brain/`（本プロジェクト） | Elixir アプリ: Fb（fb0 直描画）/ Font（5×7）/ Display（KIOSK 画面 GenServer）/ SshDaemon（:ssh + IEx + direct exec + SFTP） |
| `hello_kiosk_brain/scripts/` | build_release.sh（リリース構築 + OTP 合流）/ **screenshot.sh（実機 LCD のリモートスクリーンショット）** |
| 母艦 `/home/owner/toolchains/` | Bootlin `armv5-eabi--glibc--stable-2025.08-1`（gcc 14.3.0） |
| 母艦 NetworkManager | `brain-usb` 接続（enp0s20f0u2 に 10.42.0.1/24 を恒久設定） |

## 3. Phase 2: クロスコンパイル環境（2026-09-02）

- crosstool-NG 自作の代わりに **Bootlin ビルド済みツールチェーン**を採用
  （デフォルトで armv5tej / soft-float。Buildroot 製で Phase 3 との親和性も高い）
- クロスコンパイルした hello world が static / dynamic とも実機動作
  （dynamic は Brainux glibc 2.41 と互換 → glibc 系で確定）
- **見積り 2〜5 日の「armv5 ツールチェーン自作」タスクは丸ごと不要になった**

## 4. Phase 3: Nerves rootfs 差し替え（2026-09-02）

### 4.1 構成

- `nerves_system_br` v1.34.3（Buildroot 2026.05.2 ピン）を standalone
  （create-build.sh）で使用。**OTP 29.0.5 の armv5 クロスビルドに成功**
- カーネル・U-Boot・DTB はビルドせず buildbrain 2026-03-25 リリースの実績バイナリを流用
- rootfs は **ext4**（Brainux カーネルが squashfs 非対応のため。squashfs 化はカーネル再構築後の課題）
- SD 構成: ベースイメージを dd → p1 に nk コピー（直接ブート）+ **パッチ済み DTB** →
  p2 を mkfs.ext4 して Nerves rootfs を展開（`sd/populate_sd.sh`）

### 4.2 USB ガジェットのデバッグ経緯（重要知見）

1. **busybox に `ln` が無い** → configfs へのリンク作成が失敗
   → symlink(2) を呼ぶだけの静的ヘルパー `lns` を追加
2. **UDC が現れない** → 診断ログを SD 経由で回収して解析した結果、
   `ci_hdrc.0` が **EHCI ホストとして登録**されていた
3. **根本原因: 配布イメージの DTB は `usb@80080000` が `dr_mode="host"`**。
   動作していた Brainux SD の DTB と diff し、**brain-config の「ガジェット有効化」の
   正体は DTB の dr_mode を "peripheral" に書き換えることだった**と確定
   （機能差分はこの1点のみ）。dtc でパッチした DTB を p1 に配置して解決
4. ガジェット起動は erlinit `--pre-run-exec /usr/bin/enable_ethernet_gadget` で自動化
   （スクリプト v2: UDC 出現待ちループ + `/sys/class/udc` から実名取得）
5. 母艦で列挙されない事象が続いたが、最終的な主因は**データ非対応ケーブルの取り違え**。
   正しいケーブルなら後挿しでも列挙された

### 4.3 マイルストーン

- Nerves rootfs + OTP手動配置で **`Eshell V17.0.5`(OTP 29) が実機 LCD に表示**
- ガジェット自動構成 → 母艦に「SHARP Brain (Nerves)」列挙 → **ping 疎通（RTT 2〜4ms）**

## 5. Phase 4 コア: hello_kiosk_brain アプリ（2026-09-02）

### 5.1 リリース方式（クロスコンパイル不要）

- BEAM バイトコードはアーキテクチャ非依存 → アプリは母艦でコンパイル
- **ERTS 非同梱リリース**（`include_erts: false`）でターゲットの OTP を使用
- 母艦の OTP をターゲットと同じ **29.0.5**（mise）に揃えてバージョン名を一致させる
- **erlinit は `ROOTDIR=/srv/erlang` を設定するため、`$ROOT/lib` に OTP アプリ一式が必要**
  → `scripts/build_release.sh` が start.script を解析し、staging から
  該当 OTP アプリ（kernel/stdlib/crypto/ssh 等8個）を release/lib に合流
  （crypto の NIF も armv5 正品になる）。これを怠ると
  `{load_failed,[error_handler]}` で即クラッシュする

### 5.2 実装済み機能

- **Display**: 紺背景 + タイトル + 右上 IP + 稼働秒数を 1 秒ティックで描画
  （Fb: RGB565 LE / `:file.pwrite`、Font: 5×7 ビットマップ）
- **SshDaemon**: OTP 組み込み `:ssh`（外部依存ゼロ）
  - 公開鍵認証（母艦の鍵を priv/ssh/authorized_keys に同梱）+ パスワード(user/brain)
  - IEx シェル / **direct exec**（`ssh user@10.42.0.2 '任意のElixir式'` で評価結果が返る）
  - SFTP サブシステム（リリース更新のネットワーク配備に使用）
- **fbcon 切り離し**: カーネルコンソールが KIOSK 画面へログを上書きするため、
  Display.init で vtconsole を unbind

### 5.3 ハマりどころと解法

| 事象 | 解法 |
|---|---|
| `{load_failed,[error_handler]}` でブート即死 | §5.1 の OTP アプリ合流（build_release.sh に組み込み済み） |
| ssh 接続が即切断 | shell オプションは「チャネル寿命を握る pid を返す fun」が必要。`{IEx,:start,[]}` は不可 → `fn _,_ -> spawn(fn -> IEx.Server.run([]) end) end` |
| exec が `Prohibited.` | OTP の ssh はデフォルト exec 無効 → `exec: {:direct, fun}` で Elixir 評価器を提供 |
| ログが KIOSK 画面に上書き | vtconsole unbind（コード恒久化済み） |
| LCD 左右端の乱れ・黒帯・緑残り | 真因は **braindrmfb(brain-hackers の DRM ドライバ)が /dev/fb0 への細かい行単位 write を取りこぼす/カーネル内で `enospc`・ハングする**こと（2026-09-03 実機切り分け: 行単位 fill は反映されず、全画面1回の連続 write は完全反映）。対策として **Fb をシャドウフレーム方式に全面改修**: 全描画はメモリ上の行バイナリ Map に対して行い、デバイスへは `flush/1` がフレーム全体を**1回の :file.pwrite**で書く。draw 系は %Fb{} を返す関数型 API に変更。Display は描画バッチ末尾で必ず flush |
| **SD カードの取り違えで長時間デバッグが迷走**（2026-09-03） | Nerves SD が2枚あり、SFTP 配備先(起動中の別 SD)と母艦で検証していた SD が別物だった。「新 beam なのに旧コードが動く」矛盾の正体。**教訓: beam の新旧は md5 でなく vsn(beam_lib chunks の attributes)で判定でき、crash_dump 内の各モジュールの vsn と突き合わせれば実際にロードされたコードを一意に特定できる**（Brain は RTC 無しで全ファイル・全ダンプが 1970 表記のためタイムスタンプは使えない） |

### 5.4 リモート開発サイクル（確立済み・実証済み）

```sh
# 1. ビルド（リリース + OTP 合流）
./scripts/build_release.sh
# 2. 変更 beam を SFTP で転送（例: アプリ ebin 一式）
#    → 実績: sftp バッチで /srv/erlang/lib/hello_kiosk_brain-0.1.0/ebin へ put
# 3. ホットリロード（再起動不要）
ssh user@10.42.0.2 ':code.purge(M); :code.load_file(M); GenServer.stop(HelloKioskBrain.Display)'
# 4. 画面確認（実機 LCD をリモートで PNG 化）
./scripts/screenshot.sh
```

初回のみ SD へ `sd/deploy_release.sh`（sudo）で配置。以後 SD 往復は不要。

## 6. 工数実績 vs 見積り

| フェーズ | 見積り(提案書v1.1) | 実績 | 差の要因 |
|---|---|---|---|
| Phase 0〜1 | 2.5〜5日 | 2日 | ほぼ計画通り |
| Phase 2 | 2〜5日 | **半日** | Bootlin 採用で自作不要に |
| Phase 3 第1段階 | 1〜3週間 | **1日** | ctng 不要 + カーネル流用が奏功。DTB 問題も同日解決 |
| Phase 4 コア | 3〜7日 | **半日** | バイトコード非依存を活かした ERTS-less 方式 |

## 7. 残タスク

1. **evdev キーボード入力**（優先。コンソールキーマップ非経由なので「7」「"」問題は解消見込み）
2. ~~Display の IP 再描画チラつき修正~~（✅ 2026-09-03: 変化時のみ再描画に変更。
   同日 **Fb の動的解像度化**も完了 — sysfs から virtual_size/stride/bpp を取得する
   構造体ベース API へ刷新、screenshot.sh も解像度非依存化。PW-SH1(800×480) 等にも
   コード変更なしで追従可能に）/ 左右マージン対応は未
3. KIOSK フレームワーク移植（kiosk_7inch / raspad3 の描画 API のバックエンド化）
4. タッチ対応（座標補正のみ、向き変更はしない）
5. Phase 3 第2段階: fwup / A/B パーティション / erlinit.config 本番化
   （-v 解除、run-on-exit 方針、VM 異常時の自動再起動）
6. カーネル再構築時: squashfs 有効化 → read-only rootfs 化
