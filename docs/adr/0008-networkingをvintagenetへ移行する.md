# 0008: networking を VintageNet / NervesPack へ移行する

## 状態

採用（USB NCM 実機確認済み）

## 背景

これまでの PW-SH6 bring-up では、`erlinit --pre-run-exec` から shell script を起動し、
USB Ethernet の DHCP、WiFi の `wpa_supplicant` / DHCP、USB-NCM の固定 IP 設定を行っていた。
これは初期 bring-up では有効だったが、application から見ると通常の Nerves networking と異なり、
interface state、DHCP、WiFi 設定、mDNS が shell script 側に分散していた。

一方、USB0 の host / peripheral role 自体は Device Tree で決まり、peripheral mode では Linux
configfs に NCM gadget を作る PW-SH6 固有処理が必要である。この hardware setup まで
VintageNet に持たせる必要はない。

## 決定

network interface の設定と lifecycle は `NervesPack` / `VintageNet` に移行する。
ADR 0004 の「USB-NCM を開発用通信経路とする」判断は維持し、その中の固定 IP / shell script による
userspace network 設定だけを本 ADR で置き換える。

- `usb0`: `VintageNetDirect`
- `eth0`: `VintageNetEthernet` + DHCP
- `wlan0`: `VintageNetWiFi`
- SSH / mDNS: `NervesPack` が提供する `NervesSSH` / `mdns_lite`
- WiFi credentials は `/etc/wpa_supplicant.conf` を直接編集せず、VintageNet の runtime/application
  configuration として管理する。

System 側には PW-SH6 固有の hardware setup だけを残す。

- peripheral DTB の場合は configfs で USB NCM gadget を作り `usb0` を出現させる。
- gadget helper は IP address を設定しない。`usb0` の address と peer DHCP は
  `VintageNetDirect` が管理する。
- Brain 固有 RTC の restore と Bluetooth audio daemon の準備は networking から分離し、
  `erlinit` の明示的な pre-run helper とする。

従来の `enable_net`、`enable_wired_lan`、`enable_wifi`、custom `udhcpc` hook、
`wpa_supplicant.conf.template` は削除する。

この判断は [0004: USB-NCM を開発用通信経路とする](0004-usb-ncmを開発用通信経路とする.md) のうち、
固定 `10.42.0.2/24` と shell script による IP 設定の部分を置き換える。USB-NCM を主要な
開発用通信経路とする判断自体は維持する。

## 理由

- Nerves application から interface state と設定を標準 API (`VintageNet`) で扱える。
- USB direct / USB Ethernet / WiFi の違いを application configuration に集約できる。
- USB gadget の生成という hardware-specific concern と、IP/DHCP という networking concern を分離できる。
- `VintageNetDirect` により USB direct 接続の peer address も DHCP で設定でき、開発 PC に
  `10.42.0.1/24` を手動設定する必要がなくなる。
- shell script に route / DNS / DHCP の policy を持たせなくてよくなる。

## 影響

- USB-NCM の Brain 側 address は従来の固定 `10.42.0.2/24` ではなく、`VintageNetDirect` が
  hostname/interface から選ぶ /30 subnet になる。接続先は `nerves.local` または実際に割り当てられた
  address を使用する。
- WiFi は committed placeholder `wpa_supplicant.conf` を使わない。初期 firmware は wlan0 を
  VintageNetWiFi 管理下に置くが、接続先 credential は別途設定する。
- `wpa_supplicant` は VintageNetWiFi が生成する configuration を扱えるよう WPA3 / control interface
  などを Buildroot で有効化する。
- USB NCM + `VintageNetDirect` + NervesSSH の経路は 2026-09-22 に PW-SH6 実機で確認済み。
  詳細は [`20260922-usb-ncm-real-device-verification.md`](../worklog/20260922-usb-ncm-real-device-verification.md) を参照する。
- ARMv5 / 128 MiB 環境での `NervesPack`、VintageNet、OneDHCPD の CPU / memory / startup cost は
  未計測であり、実機入手後に確認する。

## 再評価条件

- VintageNetDirect が PW-SH6 の NCM gadget (`usb0`) を安定して管理できない場合。
- USB Ethernet adapter の interface 名が `eth0` 以外になる実機構成を標準化する必要が生じた場合。
- VintageNetWiFi / OneDHCPD の resource cost が ARMv5 で実用上問題になる場合。
- Bluetooth audio と network interface bring-up の起動順に実機依存が見つかった場合。
