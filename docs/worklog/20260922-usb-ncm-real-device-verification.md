# 2026-09-22 USB NCM 実機検証

## 目的

networking policy を NervesPack / VintageNet へ移行した後の、SHARP Brain PW-SH6 実機における
USB 開発経路を確認する。

```text
PW-SH6 peripheral DTB
  -> erlinit によるハードウェア準備
  -> configfs NCM gadget
  -> VintageNetDirect
  -> mDNS
  -> NervesSSH / IEx
```

firmware は通常の application flow で生成し、`mix burn` で blank microSD に書き込んだ。
`complete` task は host-mode DTB を配置するため、burn 後に `sd/use_usb_ncm.sh` を実行し、
p1 の `imx28-pwsh6.dtb` を peripheral 版へ置き換えた。

## 調査結果 1: erlinit の pre-run command は1つだけ保持される

最初の peripheral boot では Nerves まで起動し KIOSK も描画されたが、Linux host 側では
NCM device が列挙されなかった。また、p2 に作成されるはずの gadget 診断ログも存在しなかった。

generated / burned の `erlinit.config` を確認したところ、複数記述した `--pre-run-exec` が
PW-SH6 用 helper 3つをすべて保持していないことが分かった。`erlinit` v1.15.1 の
`pre_run_exec` は単一文字列として扱われるため、後から指定した値で前の値が上書きされる。

System 側では、現在は1つだけ指定する。

```text
--pre-run-exec /usr/bin/prepare_brain_hardware
```

`prepare_brain_hardware` から各処理を分離したまま、次の順序で呼び出す。

```text
restore_brain_rtc
enable_ethernet_gadget
enable_bt_speaker
```

これにより、hardware preparation を networking policy より下の層に保ちつつ、
`erlinit` の実際の option semantics に合わせられる。

## 調査結果 2: gadget helper には BusyBox tr が必要

pre-run helper を1つに集約した後、`/root/gadget_diag.log` が生成され、
`enable_ethernet_gadget` 自体は実行されていることを確認できた。ただし Device Tree property の
読み取り時点で停止していた。

```text
/usr/bin/enable_ethernet_gadget: line 15: tr: not found
dr_mode=
skip: USB0 is not peripheral
```

Device Tree の文字列 property は NUL 終端のため、helper では `tr -d '\000'` を使用する。
しかし System の BusyBox 設定では `tr` が有効になっていなかった。

そのため `busybox.fragment` では、gadget setup で使用する applet を明示的に有効化する。

```text
CONFIG_LN=y
CONFIG_TR=y
```

fragment を変更した後は Buildroot output の再生成が必要である。この検証では、古い `o/.config` に
削除済みの `post-build-wifi.sh` が残っていたため、`create-build.sh nerves_defconfig o` を再実行して
Buildroot configuration を現在の `nerves_defconfig` と同期してから再ビルドした。

burn 前に、最終 rootfs に `tr` が入っていることを確認した。

```text
o/target/usr/bin/tr -> ../../bin/busybox
./usr/bin/tr -> ../../bin/busybox   # o/images/rootfs.tar 内
```

## 実機結果

firmware を再ビルドして burn し、peripheral DTB を選択して起動したところ、Linux 開発 PC 側で
PW-SH6 が CDC NCM device として列挙された。

```text
Product: Brain (Nerves)
Manufacturer: SHARP
cdc_ncm ... MAC-Address: 8a:15:8b:44:3a:01
cdc_ncm ... enx8a158b443a01: renamed from usb0
```

host 側には peer address が自動で割り当てられた。この boot では次の値だった。

```text
PW-SH6 usb0: 172.31.172.181/30
Linux host:   172.31.172.182/30
```

これらは実測例であり、固定値として扱う契約ではない。/30 subnet の選択と DHCP behavior は
`VintageNetDirect` が管理する。

host 側で手動 IP 設定を行わずに、mDNS と SSH が動作した。

```text
ping nerves.local
ssh user@nerves.local
```

`ssh user@nerves.local` から通常の Nerves IEx session に接続できた。target 側の
`VintageNet.info()` では次のように確認できた。

```text
Interface usb0
  Type: VintageNetDirect
  Present: true
  State: :configured
  Connection: :lan
  Addresses: ... 172.31.172.181/30
```

想定していた application も起動していた。

```elixir
[:nerves_pack, :mdns_lite, :vintage_net, :nerves_ssh]
```

`ifconfig()` でも `usb0` が up/running であり、IPv4 と IPv6 link-local address が設定されていることを
確認した。

## 現時点で残している境界

- `mix upload` / OTA firmware update は引き続き未サポートとする。現在の writable single-root ext4
  layout には安全に書き換えられる inactive slot がなく、`upgrade` task も意図的に無効化している。
- `mix burn` を実行すると p1 の DTB は host-mode に戻る。USB NCM を使う開発経路では、burn のたびに
  `sd/use_usb_ncm.sh` を実行する。
- `Nerves.Runtime.KV.get_all()` は現在 `%{}` を返すため、Nerves MOTD では
  `unknown 0.0.0 - unknown` / `Platform: unknown` と表示される。これは System metadata の別課題であり、
  boot、networking、SSH の動作には影響しなかった。
- `/root/gadget_diag.log` は bring-up 用の診断 instrumentation である。USB role path を安定化する間は
  有用だが、障害時の観測性が十分と判断できた段階で、独立して簡略化または削除できる。
