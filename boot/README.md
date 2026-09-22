# PW-SH6 のブート用ファイル

`mix firmware` で blank SD カードを既存の direct-SD boot path から起動可能にするには、
このディレクトリに次の3ファイルが必要になる。

- `edsh6exe.bin`: PW-SH6 NK/U-Boot loader
- `zImage`: Linux kernel
- `imx28-pwsh6.dtb`: PW-SH6 host-mode Device Tree

これらは固定して使用している
[brain-hackers/buildbrain 2026-03-25-024518 release](https://github.com/brain-hackers/buildbrain/releases/tag/2026-03-25-024518)
の成果物を利用する。バイナリ自体はこのリポジトリには commit せず、次の script で取得する。

```sh
scripts/fetch_boot_assets.sh
```

取得時には upstream archive の SHA-256 を検証してから展開する。
既定以外の配置先を使う場合は script の第1引数に path を渡し、`mix firmware` 実行時にも同じ path を
`BRAIN_BOOT_DIR` に設定する。

System artifact を公開する場合は、`mix nerves.artifact` より先に取得 script を実行する。
custom artifact platform が取得済み bundle を artifact に含めるため、その artifact の利用者は
firmware build 時に upstream archive を再取得する必要がない。

既定の DTB は upstream の host-mode DTB である。USB NCM を使う場合は、firmware を SD に書き込んだ後、
application または `sd/use_usb_ncm.sh` で peripheral-mode DTB に置き換える。

boot loader と kernel は upstream の third-party work である。ライセンスと対応する source については
`NOTICE`、`REUSE.toml`、upstream source repository を参照する。
