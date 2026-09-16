# 0002: Bootlin ARMv5 ツールチェーンを採用する

## 状態

採用

## 背景

PW-SH6 の CPU は ARM926EJ-S（ARMv5TEJ）であり、ハードウェア浮動小数点演算を前提に
できない。rootfs、Erlang/OTP、NIF、補助プログラムは、ARMv5 の soft-float ABI と
互換性のあるツールチェーンで構築する必要がある。

専用ツールチェーンを crosstool-NG で新規作成する案もあったが、Bootlin の
`armv5-eabi--glibc--stable` で構築した静的・動的プログラムと Erlang/OTP が PW-SH6 で
動作することを確認できた。

## 決定

Buildroot が提供する Bootlin `armv5-eabi--glibc--stable` ツールチェーンを使用する。
`nerves_defconfig` では
`BR2_TOOLCHAIN_EXTERNAL_BOOTLIN_ARMV5_EABI_GLIBC_STABLE` を選択する。

## 理由

- ARMv5TEJ、soft-float、glibc の組み合わせが対象機で動作している。
- Buildroot が取得と設定を管理するため、独自ツールチェーンの保守を避けられる。
- `nerves_system_br` による rootfs と Erlang/OTP の構築へそのまま利用できる。

## 影響

- ビルドは Bootlin および Buildroot が提供する外部成果物に依存する。
- NIF や `devmem` などのネイティブコードも、同じ ABI のクロスコンパイラで構築する必要がある。
- ツールチェーンの版を更新する場合は、生成物の ABI と PW-SH6 上での動作を再確認する。
- 独自の Nerves toolchain パッケージは、必要性が明確になるまで作成しない。

## 再評価条件

- Bootlin の対象 toolchain が取得・再現できなくなった場合。
- Nerves 公式/コミュニティの ARMv5 toolchain を利用する明確な利点が生じた場合。
- toolchain 更新が必要になった場合は、ABI と OTP/NIF の実機動作を含めて再評価する。
