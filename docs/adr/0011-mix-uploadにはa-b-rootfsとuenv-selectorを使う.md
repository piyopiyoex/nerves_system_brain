# 0011: mix upload には A/B rootfs と uEnv selector を使う

## 状態

採用

## 背景

ADR 0007 では、blank SD provisioning と remote update を分離し、single-root の p2 を実行中に
上書きしないため `mix upload` を有効化しなかった。その後、PR #44 の流れで `mix firmware` / `mix burn`、
NervesSSH、HOST / NCM の切り替えまで標準 Nerves の仕組みに寄せられ、remote update の transport は
`NervesSSH -> ssh_subsystem_fwup -> fwup` をそのまま利用できる状態になった。

一方、storage 側は writable ext4 の p2 だけであり、running rootfs を安全に全体更新することはできない。
固定 buildbrain 2026-03-25-024518 の PW-SH6 U-Boot は FAT p1 の `uEnv.txt` を import し、`sdroot` を
上書きできるため、p2 / p3 を rootfs slot として切り替えられる。

## 決定

standard `mix upload` の transport をそのまま使い、rootfs を A/B 化する。

- p1 は shared FAT boot partition とし、boot loader、kernel、HOST / NCM DTB、slot selector を置く。
- p2 を rootfs slot A、p3 を rootfs slot B とし、それぞれ 256 MiB とする。
- `complete` task は slot A に firmware を書き、p1 の `uEnv.txt` で `/dev/mmcblk1p2` を選択する。
- p1 には `uEnv.a.txt` / `uEnv.b.txt` も置き、更新時の selector source と manual recovery に使う。
- `mix upload` は NervesSSH が提供する standard `fwup` SSH subsystem を使い、task prefix `upgrade` を
  `/dev/mmcblk1` に適用する。application 固有の upload command や独自 protocol は追加しない。
- `upgrade.a` / `upgrade.b` は metadata の active slot だけに依存せず、実際に mount されている `/` の
  device と block offset を確認して inactive slot を決める。これにより selector と metadata が一時的にずれても
  running rootfs を上書きしない。
- update は inactive rootfs 全体を書き終えて slot metadata を記録した後、全 firmware resource の受信が
  完了した `on-finish` で `uEnv.txt` を切り替える。selector は temporary file を経由して置き換える。
- `mix upload` は shared p1 の `zImage`、DTB、`edsh6exe.bin` を更新しない。現在選択している HOST / NCM
  mode も維持する。kernel / DTB / loader を変更する System update は `mix burn` で行う。
- upload 成功後の reboot は `ssh_subsystem_fwup` の標準 success callback に任せる。
- 現段階では automatic health check / rollback を導入しない。書き込みが成功した slot は validated として
  metadata に記録する。新 firmware が boot しない場合は microSD を Linux PC に接続し、p1 の
  `uEnv.a.txt` / `uEnv.b.txt` から前の slot を `uEnv.txt` に戻して recovery する。
- 旧 p1+p2 layout は in-place migration せず、一度 `mix burn` で current A/B layout に作り直してから
  `mix upload` を使用する。

ADR 0007 の「A/B update を別設計とし `mix upload` を有効化しない」という判断、および ADR 0010 の
「A/B update / `mix upload` は別設計」という部分は、この ADR で置き換える。

## 理由

- developer-facing workflow を通常の Nerves と同じ `mix firmware` / `mix upload` にできる。
- running ext4 rootfs を直接上書きせず、power loss や upload 中断時も current slot を保持できる。
- PW-SH6 固有処理を p1 の `uEnv.txt` selector に限定し、application / SSH transport に custom 実装を
  持ち込まずに済む。
- HOST / NCM の active DTB は shared p1 に残すため、remote application update と USB mode selection の
  責務を混ぜずに済む。
- bootcount を持たない現行 U-Boot に automatic rollback を擬似実装せず、まず実機で A -> B -> A の
  update path を検証できる。

## 影響

- fresh `mix burn` が作る media は FAT p1 + ext4 p2(A) + ext4 p3(B) になる。
- current layout 導入前に作った SD は、`mix upload` の前に再度 `mix burn` する必要がある。
- application-only update は `mix firmware` の後に `mix upload nerves.local` で反映できる。
- upload 後も p1 の active DTB は変わらないため、NCM で接続中なら reboot 後も NCM、HOST なら HOST を
  維持する。
- kernel / Device Tree / boot loader の変更は `mix upload` では反映されない。
- remote update 後に新 slot が起動不能になるケースは自動では復旧しない。現段階では microSD を取り出す
  manual recovery を前提とする。
- host-side `fwup` check は CI で行い、PW-SH6 実機の A -> B -> A 往復と upload 中断時の挙動は導入時に確認する。

## 再評価条件

- U-Boot の bootcount / altbootcmd などを使った automatic rollback が実機で成立する場合。
- application startup / network reachability を使った slot health confirmation を導入する場合。
- kernel / DTB も A/B 化し、System 全体を `mix upload` で更新する必要が生じた場合。
- writable ext4 rootfs を read-only rootfs + data partition に再構成する場合。
