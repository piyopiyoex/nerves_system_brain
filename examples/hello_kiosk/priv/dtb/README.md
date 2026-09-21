# priv/dtb — USB0 の役割を切り替えるための Device Tree(PW-SH6)

`HelloKioskBrain.UsbMode` がホーム画面の「USB」ダイアログから boot パーティション(`/dev/mmcblk1p1`)の
`imx28-pwsh6.dtb` をこれらで置き換え、再起動する。U-Boot(`edsh6exe.bin`)が読むファイル名は固定なので
「どちらを imx28-pwsh6.dtb にコピーしてあるか」で役割が決まる。

| ファイル | dr_mode | 用途 | 由来 |
|---|---|---|---|
| `pwsh6-host.dtb` | host | 有線 LAN / WiFi / BLE / USB オーディオ / BT スピーカー(セルフパワーハブ経由) | brain-hackers buildbrain 2026-03-25 の `imx28-pwsh6.dtb` + buzzer/PWM4 ノード有効化(2026-09-05)。md5 65e1d36a |
| `pwsh6-peripheral.dtb` | peripheral | USB NCM ガジェット(母艦と直結、usb0 10.42.0.2) | 上と同一で `dr_mode = "peripheral"` のみ差し替え(md5 0ad4081f、旧 `imx28-pwsh6.dtb.ncm-buzzer`) |

2 つの差分は `dr_mode` の 1 行だけ(`dtc -I dtb -O dts` で確認)。ライセンスは linux-brain 由来の GPL-2.0-or-later。
他機種(PW-SH1 等)の変種は未収録 → ダイアログは「この機種は非対応」を表示する。
