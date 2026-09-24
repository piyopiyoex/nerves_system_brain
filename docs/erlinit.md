# PW-SH6 の erlinit 立ち上げ用プロファイル

## 現在の位置づけ

`rootfs_overlay/etc/erlinit.config` は、PW-SH6 の実機 bring-up と USB NCM を使った開発を
優先した現在の設定である。起動ログ、LCD コンソール、Erlang 終了後の調査用 shell などを
意図的に有効にしている。

この設定は将来の製品運用構成を定義するものではない。bring-up が完了した後に、診断性と
運用上の要件を見ながら不要な項目を個別に再評価する。現時点では通常運用用の別 profile を
追加せず、実機で使用している構成を一つに保つ。

USB NCM も同様に、現在の主要な**開発用通信経路**としてこの profile に含まれている。
製品運用時に USB NCM を常設することを意味しない。通信経路についての設計判断は
[`adr/0004-usb-ncmを開発用通信経路とする.md`](adr/0004-usb-ncmを開発用通信経路とする.md) を参照する。

現在使用している `nerves_system_br` v1.34.3 は `erlinit` v1.15.1 を使用する。
各 option の仕様は upstream の `erlinit` ドキュメントを基準とする。

## 設定項目

| 設定 | 区分 | 目的 |
|---|---|---|
| `-v` | bring-up | `erlinit` の起動処理を詳細表示し、初期化時の調査をしやすくする |
| `-c tty1` | PW-SH6 固有 / bring-up | LCD の fbcon と内蔵キーボードを Erlang console として使用する |
| `--warn-unused-tty` | bring-up | kernel log が Erlang console ではない tty に出ている場合に警告する |
| `LANG`, `LANGUAGE` | 通常動作 | UTF-8 locale と表示言語を設定する |
| `ERL_INETRC` | 通常動作 | Erlang の名前解決設定として `/etc/erl_inetrc` を指定する |
| `ERL_CRASH_DUMP`, `ERL_CRASH_DUMP_SECONDS` | 障害解析 | crash dump の出力先を指定し、出力時間を 5 秒に制限する |
| `-m configfs:...` | USB NCM 開発用 | gadget setup に必要な configfs を Erlang 起動前に mount する |
| `-r /srv/erlang` | 通常動作 | application release の検索場所を指定する |
| `--boot shoehorn` | Nerves 標準 / PoC | `shoehorn.boot` を優先して起動し、standard Nerves app boot path に寄せる |
| `--pre-run-exec /usr/bin/prepare_brain_hardware` | PW-SH6 固有 | RTC restore、USB NCM gadget、Bluetooth audio の各 helper を1つの pre-run command から順に実行する |
| `--run-on-exit /bin/sh` | bring-up | Erlang 終了後に調査用 shell を起動する |

`erlinit` v1.15.1 の `--pre-run-exec` は単一の command だけを保持する。複数回指定すると後の値で
上書きされるため、PW-SH6 固有処理は `prepare_brain_hardware` に集約し、個別 helper はそこで順に呼び出す。
USB NCM helper が使用する `ln` と `tr`、`brain-usb-mode` が使用する `sync` は `busybox.fragment` で明示的に有効化している。

`--run-on-exit` は Erlang が終了したときに指定した command を実行する option であり、
異常終了時だけに限定されない。現在は `/bin/sh` を指定し、終了理由や system の状態を
実機上で確認できるようにしている。shell を終了した後は `erlinit` の通常の終了処理へ進む。

## 起動の流れ

peripheral / USB-NCM 構成では、概ね次の順序で起動する。

```text
Linux kernel
    ↓
erlinit (PID 1)
    ↓
tty / environment / configfs mount
    ↓
PW-SH6 hardware preparation
    ├─ restore_brain_rtc
    ├─ enable_ethernet_gadget  → usb0 を作るだけ
    └─ enable_bt_speaker       → 設定時のみ
    ↓
/srv/erlang の Nerves release
    ↓
shoehorn
    ↓
nerves_runtime + nerves_pack
    ↓
VintageNet
    ├─ usb0  → VintageNetDirect
    ├─ eth0  → VintageNetEthernet / DHCP
    └─ wlan0 → VintageNetWiFi
    ↓
hello_kiosk
```

`erlinit` は hardware-specific な準備だけを行う。IP address、DHCP、WiFi、route、DNS の lifecycle は
BEAM 起動後に VintageNet が管理する。これにより System の shell script に network policy を持たせない。

Erlang が終了した場合は、現在の `--run-on-exit /bin/sh` により調査用 shell が起動する。
この shell は bring-up のために意図的に残している。

## Device Tree との関係

USB NCM を使用する場合、この profile は USB0 が `peripheral` mode の Device Tree を前提とする。
本リポジトリでは `boot/imx28-pwsh6-peripheral.dtb` をその用途で管理している。
`enable_ethernet_gadget` は Device Tree の `dr_mode` を確認し、peripheral のときだけ configfs gadget を作る。
address は設定せず、application 側の `VintageNetDirect` に引き渡す。2026-09-22 の実機確認では
`usb0` が `:configured` / `:lan` になり、Linux PC から `nerves.local` と NervesSSH/IEx で接続できた。

USB Ethernet、USB Audio、USB 接続の WiFi / BLE などで USB0 を host として使用する場合は、
brain-hackers 由来の host 構成を選択する。USB0 の host mode と USB NCM gadget は同時には使用できない。
network interface が現れた後の設定は VintageNet が担当する。HOST / NCM の切り替えは System の
`brain-usb-mode` に集約し、application はその helper を呼ぶだけにする。DTB の選択方針は
[PW-SH6 の Device Tree](usb-mode.md) を参照する。


## 将来の運用構成で再評価する項目

bring-up が完了した後は、少なくとも次の項目を必要性に応じて再評価できる。

- `-v` と `--warn-unused-tty` を維持するか。
- LCD と内蔵キーボードによる `tty1` console を維持するか。
- `--run-on-exit /bin/sh` を維持するか、`erlinit` の通常の終了動作へ戻すか。
- USB NCM をその運用構成でも使用するか。
- `--boot shoehorn` は標準 Nerves に寄せる PoC の既定値として PW-SH6 実機で確認済み。
  production 運用でも維持するかは、更新・復旧方式を決める段階で再評価する。

これらは現在の未完了事項を意味しない。変更するときは、PW-SH6 実機で起動、console、通信経路、
障害時の挙動を確認した上で判断する。
