# 0003: rootfs に ext4 を採用する

## 状態

採用

## 背景

流用する brain-hackers の Linux カーネルでは squashfs を利用できない。一方、現在の
立ち上げ段階では、診断結果の保存、設定変更、release の手動更新を対象機上で行う必要がある。

squashfs を利用するためだけに動作実績のあるカーネルを再構築すると、起動基盤を維持する
方針に反し、検証範囲も広がる。

## 決定

rootfs には ext4 を採用する。Buildroot では 256 MiB の ext4 image と、SD カードへ手動で
展開するための `rootfs.tar` を生成する。

立ち上げ段階では buildbrain の SD カード第2区画を ext4 で初期化し、Nerves rootfs を
展開する方式を使用する。

## 理由

- 現在の Linux カーネルで利用でき、カーネルの変更を必要としない。
- buildbrain の既存区画構成を保ったまま rootfs だけを差し替えられる。
- 診断や初期開発に必要な書き込みを単純な手順で行える。

## 影響

- rootfs は書き込み可能であり、電源断による破損への耐性は read-only rootfs より低い。
- 現時点では `fwup`、A/B 更新、read-only rootfs の恩恵を利用できない。
- SD カード作成時には対象区画を再初期化するため、誤ったデバイスを選ばない安全対策が必要となる。
- read-only rootfs への移行は必須とはせず、対応カーネルと運用上の必要性が揃った場合に再評価する。

## 再評価条件

- 電源断耐性や field update を重視する運用へ移る場合。
- 対応 kernel で read-only rootfs を安定して利用できる見通しが立った場合。
- system data と永続データを分離し、A/B 更新や `fwup` を採用する価値が出た場合。
