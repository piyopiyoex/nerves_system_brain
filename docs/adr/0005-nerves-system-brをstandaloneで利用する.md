# 0005: nerves_system_br を standalone で利用する

## 状態

採用

## 背景

一般的な Nerves System は Mix の依存関係として取得され、system artifact と `fwup` を使って
ファームウェアを生成する。本プロジェクトでは、PW-SH6 の既存起動基盤と SD カード構成を
維持しながら、まず Nerves 互換の rootfs と Erlang/OTP を成立させる必要がある。

この段階で標準的なファームウェア生成と更新方式まで導入すると、未検証の区画設計や起動処理が
同時に増え、ハードウェア立ち上げ時の問題を切り分けにくくなる。

## 決定

当面は `nerves_system_br` の `create-build.sh` を直接使用する standalone 構成とする。
このリポジトリは Buildroot の設定と rootfs overlay を管理し、アプリケーションは
`hello_kiosk_brain` で管理する。

生成した rootfs、対象機向け Erlang/OTP、アプリケーション release は、既存の SD カード構成へ
明示的な手順で配置する。

## 理由

- rootfs の成立確認に必要な変更だけへ範囲を限定できる。
- U-Boot、カーネル、区画構成を変更せず、既知の起動環境を維持できる。
- system 固有処理とアプリケーション固有処理を別のリポジトリに保てる。

## 影響

- 現在のビルドと配置は `mix firmware` や `fwup` だけでは完結しない。
- `nerves_system_br` の版を明示的に固定し、standalone のビルド手順を保守する必要がある。
- rootfs、Erlang/OTP、アプリケーション release の配置手順が分かれている。
- 起動とストレージが安定した後、通常の Nerves System package、system artifact、`fwup`、
  A/B 更新へ移行する価値を改めて評価する。
