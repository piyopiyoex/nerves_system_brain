# Phase 0 実機検証手順書：USB Host + USB-Ethernet 有線 LAN

- 日付: 2026-09-03
- 対象: SHARP Brain PW-SH6（i.MX283 / ChipIdea OTG USB）
- 前提: **既に SSH が動く Brainux 環境**で実施（Nerves は一切いじらない）
- 目的: 「PW-SH6 の microUSB が USB Host + 給電を通し、USB-Ethernet で LAN に参加できるか」を
  ハード可否として確定する
- 親文書: [20260903_有線LAN化_USBホスト_提案書.md](20260903_有線LAN化_USBホスト_提案書.md)

---

## 0. 必要機材

| 機材 | 備考 |
|---|---|
| USB-Ethernet アダプタ | **RTL8152/8153** か **ASIX AX88772/AX88179**（Linux 定番） |
| USB OTG ケーブル / アダプタ | microUSB(オス) ⇔ USB-A(メス)。ID ピン結線のもの |
| **セルフパワー USB Hub** | **VBUS 給電が通らない前提で最初から用意**。外部電源付き |
| Y字/給電ケーブル | Hub が無い場合の外部 5V 供給用 |
| 実験用 microSD | Brainux + **host 版 DTB**。通常運用 SD とは別に用意（戻れる設計） |
| LAN 環境 | DHCP サーバー(ルータ) + 同一 LAN の PC |

## 1. 準備: 実験用 host DTB を作る（母艦で）

通常運用 SD は温存し、**実験用 SD** の p1 の DTB だけ host 版に差し替える。

```sh
# 配布オリジナル(host)をそのまま使えるか、あるいは現行から dr_mode を戻す
cd /home/owner/my_nerves_examples/nerves_system_brain/sd
dtc -I dtb -O dts imx28-pwsh6-working.dtb -o pwsh6-host.dts
#  usb@80080000 の dr_mode を "peripheral" → "host" に、
#  vbus-supply の有無も確認（あればそのまま、無ければ後で検討）
#  （配布オリジナルは元々 host。working.dtb は既に peripheral 化されている点に注意）
dtc -I dts -O dtb pwsh6-host.dts -o imx28-pwsh6-host.dtb
```

- 実験用 SD の p1(FAT) の `imx28-pwsh6.dtb` を `imx28-pwsh6-host.dtb` に置換
- **注意**: host 化すると USB-NCM は使えなくなる。実験中の Brain への接続は
  **LCD コンソール + 本体キーボード**（または UART が取れれば UART）で行う

## 2. Phase 0-A: USB Host そのもの

OTG ケーブル + セルフパワー Hub 経由で **USB メモリ**を挿す。Brain のコンソールで:

```sh
dmesg | tail -30           # "new high-speed USB device" 等が出るか
lsusb                      # デバイスが列挙されるか
ls /dev/sd*                # マスストレージなら sda 等
```

判定 A: ☐ USB デバイスを認識した / ☐ 何も出ない（→ §6 VBUS 対策へ）

## 3. Phase 0-B: USB-Ethernet NIC 認識

USB メモリを抜き、**USB-Ethernet アダプタ**を挿す（LAN ケーブルはまだ繋がなくてよい）。

```sh
dmesg | tail -30           # r8152 / ax88179_178a / cdc_ether 等のドライバ行
ip link                    # 新しい ethX が生成されるか（実名を記録）
ethtool eth0 2>/dev/null   # あれば（ドライバ名確認）
```

判定 B: ☐ NIC ドライバがロードされた / ☐ ロードされない（→ カーネルにドライバ無し = Phase 1 が必要）
判定 C: ☐ インターフェース生成、実名 = __________（eth0/eth1/…）

## 4. Phase 0-C: LAN 通信

LAN ケーブルを繋ぐ。（`<IF>` は 0-C で記録した実名）

```sh
ip link set <IF> up
udhcpc -i <IF>             # DHCP。または dhclient <IF>
ip addr show <IF>          # IP が付いたか
ip route                   # デフォルトルート
ping -c 3 <ルータのIP>
ping -c 3 <同一LANのPCのIP>
ping -c 3 8.8.8.8          # 外部（ルータが NAT していれば）
```

判定 D: ☐ DHCP で IP 取得（IP = __________）
判定 E: ☐ LAN 内 PC へ ping 成功

## 5. Phase 0-D: LAN 経由 SSH と再現性

**PC 側から** Brain の LAN IP へ SSH:

```sh
# 母艦(PC)で
ssh user@<BrainのLAN_IP>          # パスワード: brain（Brainux）
```

判定 F: ☐ LAN 経由 SSH 成功

### 再現性テスト（Nerves 化の必須要件）

| # | テスト | 手順 | 結果 |
|---|---|---|---|
| G | 再起動後も自動認識 | Brain を reboot → 自動で NIC 認識・DHCP・SSH 可能か | ☐ |
| H | USB 抜き差し復旧 | アダプタを抜いて挿し直す → 再認識・再 DHCP されるか | ☐ |
| I | リンク断復旧 | LAN ケーブルを抜き挿し → リンク再確立するか | ☐ |
| J | crng 待ち測定 | 起動から SSH 可能までの時間を測る（crng は別問題として記録） | ____ 秒 |

## 6. VBUS/給電が通らない場合の対策（判定 A で NG のとき）

最大リスクはここ。順に試す:

1. **セルフパワー USB Hub** を挟む（アダプタへの給電を Hub の外部電源から）— 最有力
2. **Y字ケーブル**で microUSB の VBUS に外部 5V を供給
3. OTG ケーブルの **ID ピン結線**を確認（host モード検出に必要）
4. DTB の `vbus-supply` / `dr_mode` を再確認、`over-current` 等のログを `dmesg` で確認
5. それでも不可なら **PW-SH6 の microUSB は host 給電を通さない**と結論
   → 本方式は不成立、USB-NCM 継続

## 7. 判定まとめ（この手順書の結論欄）

- A USB Host: ☐OK ☐NG
- B/C NIC 認識・IF 実名: ☐OK（____）☐NG
- D/E DHCP・LAN 疎通: ☐OK ☐NG
- F LAN 経由 SSH: ☐OK ☐NG
- G/H/I 再現性: ☐OK ☐一部 ☐NG
- J crng 待ち: ____ 秒

**総合判定**:
- 全 OK → **有線 LAN 化 GO**。Phase 1（カーネル config に =y でドライバ追加）へ
- B/C が NG（ドライバ無し）だが A が OK → **ハードは OK**。Phase 1 のカーネル再ビルドで解決見込み
- A が NG（VBUS/OTG） → §6 を尽くしても不可なら **本方式断念、USB-NCM 継続**

## 8. 記録すべきログ（後の設計・質問用に保存）

```sh
dmesg > /root/phase0_dmesg.txt          # 全 dmesg
lsusb > /root/phase0_lsusb.txt
ip -d link > /root/phase0_iplink.txt    # hw_path 確認用（VintageNet 固定名に使う）
```

これらを母艦に回収しておくと、Phase 1（カーネル config）や VintageNet の
インターフェース固定名（`hw_path`）設計にそのまま使える。
