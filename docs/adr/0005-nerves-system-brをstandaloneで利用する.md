# 0005: nerves_system_br を standalone で利用する

## 状態

採用（0006 で段階移行を再評価中）

## 背景

一般的な Nerves System は Mix の依存関係として取得され、system artifact と `fwup` を使って
ファームウェアを生成する。本プロジェクトでは、PW-SH6 の既存起動基盤と SD カード構成を
維持しながら、まず Nerves 互換の rootfs と Erlang/OTP を成立させる必要がある。

この段階で標準的なファームウェア生成と更新方式まで導入すると、未検証の区画設計や起動処理が
同時に増え、ハードウェア立ち上げ時の問題を切り分けにくくなる。

## 決定

当面は `nerves_system_br` の `create-build.sh` を直接使用する standalone 構成とする。
このリポジトリは Buildroot の設定と rootfs overlay を管理する。動作例のアプリケーションは
`examples/hello_kiosk/` に同梱するが、Nerves システム側からは依存しない。

生成した rootfs、対象機向け Erlang/OTP、アプリケーション release は、既存の SD カード構成へ
明示的な手順で配置する。

## 理由

- rootfs の成立確認に必要な変更だけへ範囲を限定できる。
- U-Boot、カーネル、区画構成を変更せず、既知の起動環境を維持できる。
- system 固有処理とアプリケーション固有処理の責務を分離できる。

## 影響

- 現在のビルドと配置は `mix firmware` や `fwup` だけでは完結しない。
- `nerves_system_br` の版を明示的に固定し、standalone のビルド手順を保守する必要がある。
- rootfs、Erlang/OTP、アプリケーション release の配置手順が分かれている。
- 通常の Nerves System package、system artifact、`fwup`、A/B 更新は、再評価条件が
  生じた場合に採否を判断する。

## 再評価条件

- 他の Nerves アプリから通常の System dependency として利用したくなった場合。
- firmware 生成・更新を `fwup` に統一する必要が生じた場合。
- 現在の rootfs / OTP / release の分割配置が開発・運用上の負担になった場合。

再評価条件に該当するまでは、Mix System package や `fwup` の未導入を未完了タスクとは扱わない。

## 2026-09-20 追記

`examples/hello_kiosk/` 以外の Nerves application からも通常の System dependency として
利用したい要求が出てきたため、本 ADR の再評価条件に該当した。

新しい方針は ADR 0006 に分け、現在動作している standalone build / manual deployment path は
当面維持しながら、まず application development flow だけを Nerves 標準へ近づける。
