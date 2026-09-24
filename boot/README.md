# PW-SH6 のブート用ファイル

`mix firmware` で blank SD カードを既存の direct-SD boot path から起動可能にするには、
このディレクトリに boot loader、kernel、Device Tree がそろっている必要がある。

## upstream から取得する固定 asset

次の3ファイルは固定して使用している
[brain-hackers/buildbrain 2026-03-25-024518 release](https://github.com/brain-hackers/buildbrain/releases/tag/2026-03-25-024518)
の成果物を利用する。

- `edsh6exe.bin`: PW-SH6 NK/U-Boot loader
- `zImage`: Linux kernel
- `imx28-pwsh6.dtb`: PW-SH6 の HOST 用 Device Tree

バイナリ自体は source repository に commit せず、次の script で取得する。

```sh
scripts/fetch_boot_assets.sh
```

取得時には upstream archive の SHA-256 を検証してから展開する。
既定以外の配置先を使う場合は script の第1引数に path を渡し、`mix firmware` 実行時にも同じ path を
`BRAIN_BOOT_DIR` に設定する。

## NCM 用 Device Tree

USB NCM 用の Device Tree は本リポジトリで管理する。

- `imx28-pwsh6-peripheral.dts`: USB0 を `dr_mode = "peripheral"` にした派生 DTS
- `imx28-pwsh6-peripheral.dtb`: 上記 DTS から生成した DTB

再生成方法と検査方法は [`../docs/usb-mode.md`](../docs/usb-mode.md) を参照する。

## rootfs slot selector

A/B rootfs では p1 の `uEnv.txt` が次回 boot する rootfs を選ぶ。repository では次の template を管理する。

```text
uEnv.a.txt  # sdroot=/dev/mmcblk1p2 ...
uEnv.b.txt  # sdroot=/dev/mmcblk1p3 ...
```

`mix burn` は両方を p1 に置き、`uEnv.txt` は A の内容で初期化する。`mix upload` は inactive rootfs の
書き込み完了後に reference file から `uEnv.txt` を切り替える。起動不能時は Linux PC で前 slot の
reference file を `uEnv.txt` に戻して manual recovery できる。

## firmware の boot partition

`mix burn` の `complete` task は p1 に slot selector と次の3つの DTB を配置する。

```text
imx28-pwsh6.dtb             # U-Boot が実際に読む active DTB
imx28-pwsh6-host.dtb        # HOST 用の参照コピー
imx28-pwsh6-peripheral.dtb  # NCM 用の参照コピー
```

fresh burn では `imx28-pwsh6.dtb` に HOST 用 DTB を入れるため、既定の USB モードは **HOST** になる。
HOST / NCM の切り替えは active DTB だけを選択した mode の DTB で置き換え、再起動して反映する。
PW-SH6 上の helper は boot partition の参照コピーを使い、Linux PC 側の `fwup` task は firmware に
含まれる同じ System 管理 DTB を使う。

- Linux PC で SD を操作する場合: `mix burn --task usb_host` / `mix burn --task usb_ncm`
- PW-SH6 上で操作する場合: `/usr/bin/brain-usb-mode`
- KIOSK の「USB」画面: `brain-usb-mode` を呼ぶ薄い UI

System artifact を公開する場合は、`mix nerves.artifact` より先に upstream asset の取得 script を実行する。
custom artifact platform が取得済み bundle と NCM 用 DTB を artifact に含めるため、その artifact の利用者は
firmware build 時に upstream archive を再取得する必要がない。

boot loader と kernel は upstream の third-party work である。ライセンスと対応する source については
`NOTICE`、`REUSE.toml`、upstream source repository を参照する。
