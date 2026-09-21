# 0007: blank SD provisioning と A/B update を分離する

## 状態

採用

## 背景

ADR 0006 の firmware PoC は既存 SD の FAT p1 に brain-hackers の boot files があることを
前提としていた。そのため `mix firmware.burn` は MBR と p2 rootfs を生成できても、blank SD を
単独では起動可能にできなかった。

一方、`mix upload` に必要な安全な update は別の問題である。現行機は p2 を writable rootfs として
起動しており、その p2 を実行中に全体上書きすることはできない。

固定 buildbrain 2026-03-25-024518 の PW-SH6 U-Boot source を確認した結果、p1 の `uEnv.txt` を
import して `sdroot` を上書きできる。従って p2/p3 の選択は将来可能だが、bootcount、rollback、
slot health confirmation は提供されていない。

## 決定

blank SD の初回 provisioning と A/B update を別段階で扱う。

- `complete` task は fixed buildbrain release から検証済み checksum で取得する
  `edsh6exe.bin`、`zImage`、`imx28-pwsh6.dtb` を FAT p1 に書く。
- これらの third-party binary は source repository に commit しない。取得スクリプトと source URL、
  release tag、SHA-256 を管理する。
- p2 の ext4 rootfs/release を含む single-root layout は、初回 flash 用として維持する。
- A/B rootfs、p1 の boot selector、health confirmation、rollback、remote updater は一体として
  別設計・別実機検証にする。現時点で `mix upload` を有効化しない。
- `sd/populate_sd.sh` と `sd/deploy_release.sh` は legacy/recovery path として当面残す。blank SD
  firmware の実機 boot が確認され、復旧手順を文書化するまで削除しない。

## 理由

- initial provisioning は `fwup` の `fat_mkfs` / `fat_write` と ext4 image write だけで完結し、
  current boot path の安全な拡張である。
- A/B を単に p3 として追加しても、起動失敗時に戻す仕組みがなければ remote update の安全性は得られない。
- 上流の boot assets を repository に再配布せず、固定された検証済み source から取得することで、
  provenance とライセンス境界を明示できる。

## 影響

- source checkout からの `mix firmware` の初回実行には `curl`、`unzip`、`sha256sum` が必要になる。
  取得済み assets は System の `boot/` directory に再利用される。fetch 後に作った portable
  System artifact には bundle が含まれるため、その consumer は再取得しない。
- `complete` は p1 を作り直すため、既存 p1 の任意ファイルは保持しない。USB peripheral DTB は
  初回 flash 後に `sd/use_usb_ncm.sh` または application で切り替える。
- manual deployment scripts は標準 workflow の必須要素ではなくなるが、移行期間の保険として残る。

## 再評価条件

- blank SD からの実機 boot が、host / peripheral DTB の双方で確認できた場合。
- U-Boot の `uEnv.txt` 読み込みを使った p2/p3 slot selection と、power-loss 時の挙動を実機で
  評価できた場合。
- bootcount/rollback を導入する boot manager または recovery updater の責務と実装が固まった場合。
- standard `mix upload` protocol と安全な inactive-slot writer を結合できた場合。
