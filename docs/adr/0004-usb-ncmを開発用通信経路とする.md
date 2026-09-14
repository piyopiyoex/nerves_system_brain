# 0004: USB NCM を開発用通信経路とする

## 状態

採用

## 背景

PW-SH6 は開発に利用できる Ethernet や無線 LAN を内蔵していない。buildbrain の
2026-03-25 リリース系では USB NCM gadget が利用でき、PW-SH6 と開発用計算機の間で
IP 通信できることを実機で確認している。

Nerves rootfs では Brainux の `brain-config` を利用できないため、USB controller を
device モードにする Device Tree と、configfs による gadget 構成を引き継ぐ必要がある。

## 決定

立ち上げ段階の主要な通信経路として USB NCM を使用する。

USB controller は Device Tree で `dr_mode = "peripheral"` とし、`erlinit` の
`--pre-run-exec` から configfs を設定する。対象機側の `usb0` には `10.42.0.2/24` を
割り当てる。

## 理由

- buildbrain と PW-SH6 で動作実績がある。
- 専用のネットワーク機器を追加せず、母艦から SSH、SFTP、診断を利用できる。
- RNDIS よりも複数の母艦 OS で扱いやすく、既存の NCM 対応カーネルをそのまま利用できる。

## 影響

- USB controller を host モードとして同時に利用することはできない。
- gadget の初期化は UDC の検出時期と Device Tree の設定に依存する。
- IP address、MAC address、serial number は将来、複数台運用を考慮して整理する必要がある。
- USB host 化や別の通信経路への変更は、本 ADR を置き換える判断として記録し、PW-SH6
  実機で検証する。
- USB NCM は開発用通信経路であり、製品運用時の通信方式を確定するものではない。

## 再評価条件

- USB ポートを host として常用する必要が生じた場合。
- 有線 LAN / WiFi など別の通信経路を標準の開発経路にする場合。
- 複数台運用に合わせて IP / MAC / serial の管理方式を変更する場合。
