# 2026-09-20 Nerves 標準開発フロー調査

## 目的

現在の standalone に近い `nerves_system_br` の利用形態から、PW-SH6 で既に動作している
boot / storage path を維持したまま、通常の Nerves System dependency に寄せられるかを調査する。

最初の PoC では、次のコマンドが成立することを目標とする。

```sh
export MIX_TARGET=brain
mix deps.get
mix compile
```

`mix firmware` と `mix firmware.burn` は、storage model を変更せず最小限の `fwup.conf` で
成立する場合に限って後続作業として扱う。

## 比較したリポジトリ

### `nerves_system_atomcam2`

再利用できる点:

- root の `mix.exs` で `type: :system` を宣言している。
- Buildroot platform として `Nerves.System.BR` を使用している。
- target-specific な app dependency が `targets: :atomcam2` で System を選択する。
- 開発時に released System と local path dependency を切り替えられる。
- application release で `include_erts: &Nerves.Release.erts/0` を使用している。
- toolchain を Nerves の `type: :toolchain` package として表現している。

Brain 向けに調整が必要な点:

- AtomCam2 は公開済みの custom toolchain artifact を使用する。Brain は現在、Buildroot output の
  `o/host` に生成される Bootlin toolchain を使用している。
- AtomCam2 の `fwup.conf` は A/B application slot layout を前提とする。Brain の最初の移行段階では、
  現在の p1 FAT + p2 ext4 layout を維持する必要がある。
- AtomCam2 は application rootfs に squashfs を使用する。Brain で検証済みの brain-hackers kernel は
  squashfs に対応していないため、現在は ext4 が必要である。

### upstream style の System (`nerves_system_rpi3`)

再利用できる点:

- `type: :system`、`platform: Nerves.System.BR`、`platform_config: [defconfig: "nerves_defconfig"]`
  という構成。
- `TARGET_ARCH`、`TARGET_CPU`、`TARGET_OS`、`TARGET_ABI`、`TARGET_GCC_FLAGS` を `env` で提供する。
- boot / rootfs の customization を application ではなく System package 側に置く。

Brain 向けに調整が必要な点:

- upstream System は完全な firmware image と `fwup` layout を前提とする。Brain は full firmware / update
  model を採用する前に、まず System dependency として利用できる形を提供できる。
- upstream の ARM System は、より新しい ARM core と hard-float toolchain を前提とする。
  Brain は ARM926EJ-S / ARMv5TEJ / soft-float である。

### `circuits_quickstart`

再利用できる点:

- application の `mix.exs` に `@all_targets` と target-specific System dependency がある。
- `config/config.exs` から `:nerves_bootstrap` を起動する。
- target release で `include_erts: &Nerves.Release.erts/0` と
  `steps: [&Nerves.Release.init/1, :assemble]` を使用する。
- `cli/0` により `run` と `test` は既定で host 上で実行する。

Brain 向けに調整が必要な点:

- `hello_kiosk` には `/srv/erlang` へ配置する ERTS 非同梱 release の実績がある。standard Nerves release
  を追加する際も、その経路をすぐに削除しない。
- native code は Nerves environment を通してビルドする必要がある。既存 Makefile は既に `CC`、`CXX`、
  `ERTS_INCLUDE_DIR` を受け取れるため、`elixir_make` と相性がよい。

## PoC での変更

- root に `mix.exs` を追加し、`nerves_system_brain` を Nerves の `type: :system` package として定義した。
- `NervesSystemBrain.Platform` を追加した。これは `Nerves.System.BR` の小さな wrapper であり、既存の
  `o/` Buildroot output がある場合はそれを再利用し、ない場合は通常の Buildroot artifact build に
  fallback する。
- `nerves_toolchain_brain` という最小の `toolchain/` package を追加した。local development では
  `o/host` を再利用する。独立した artifact としての公開は後続課題とする。
- `examples/hello_kiosk` を target-aware な Nerves application に近づけた。target list、local System
  dependency、`elixir_make`、`Nerves.Release.erts/0`、`config/config.exs` を追加した。
- native Makefile を調整し、Nerves から渡される `CPPFLAGS` を保持することで、sysroot と target flags が
  `elixir_make` 経路でも失われないようにした。

## 調査結果

### ホスト側 PoC の確認

`examples/hello_kiosk/` から次のコマンドを実行して確認した。通常の shell では `mix` が `PATH` に
入っていなかったため、project の `mise` toolchain wrapper を使用した。

```sh
MIX_TARGET=brain mise exec -- mix deps.get
MIX_TARGET=brain mise exec -- mix compile
MIX_ENV=prod MIX_TARGET=brain mise exec -- mix release --overwrite
MIX_ENV=prod MIX_TARGET=brain mise exec -- mix firmware
```

結果:

- `mix deps.get` は `nerves_system_brain` を通常の target-specific System dependency として解決した。
- `mix compile` は `MIX_TARGET=brain` を認識し、Elixir application を compile し、Nerves environment
  経由で `elixir_make` を実行した。
- 生成された native artifact は target 用 ARM EABI5 binary だった。`priv/kiosk_nif.so` は ARM shared
  object、`priv/bin/devmem` は ARM executable である。
- `mix release` は Brain target release を `erts-17.0.5` と `shoehorn.boot` を含む形で
  `_build/brain_prod/rel/hello_kiosk_brain/` に生成した。
- `mix firmware` は Brain 固有の ext4 `rel2fw.sh` 経路を通して
  `_build/brain_prod/nerves/images/hello_kiosk_brain.fw` を生成した。
- `.fw` を `fwup -a -t complete` で展開すると、現在の p1/p2 partition geometry を持つ raw image が
  得られた。p2 を展開すると、`/srv/erlang/releases/0.1.0` と生成済み `/etc/erlinit.config` が
  root owner で存在することを確認できた。

### SD カード書き込みの確認

2026-09-21、生成した `.fw` を、p1 に known-good な brain-hackers boot files が既に入っている
準備済み SD カードへ書き込んだ。

```sh
sudo o/host/bin/fwup -a -d /dev/sda -t complete \
  -i examples/hello_kiosk/_build/brain_prod/nerves/images/hello_kiosk_brain.fw
sync
```

`fwup` は正常に完了した。

```text
100% [====================================] 17.11 MB in / 268.44 MB out
Success!
```

書き込み後の `lsblk` では、PoC で想定した partition 構成を確認した。

| パーティション | サイズ | ファイルシステム | ラベル |
| --- | ---: | --- | --- |
| `/dev/sda1` | 64M | vfat | `boot` |
| `/dev/sda2` | 256M | ext4 | `rootfs` |

SD への書き込み後、使用した `.fw` artifact をローカルでも再展開し、raw image の p2 を確認した。
release tree には次が含まれていた。

- `/srv/erlang/erts-17.0.5`
- `/srv/erlang/lib`
- `/srv/erlang/releases/0.1.0/vm.args`
- `/srv/erlang/releases/0.1.0/shoehorn.boot`
- `/srv/erlang/releases/0.1.0/start.boot`
- `/srv/erlang/releases/0.1.0/sys.config`

実 SD card block device を `debugfs` で直接確認し、生成済み `/etc/erlinit.config` が存在することも
確認した。live block device 上の release directory listing は取得した terminal output だけでは
判断できなかったため、この時点で残る確認項目は serial / console log を伴う PW-SH6 実機 boot だった。

### 最初の PW-SH6 boot 結果

最初の SD-card boot では、想定した platform layer まで到達した。

- kernel が `/dev/mmcblk1p2` を ext4 rootfs として mount した。
- `/sbin/init` が `erlinit` 1.15.1 を起動した。
- `erlinit` が release path を見つけて Erlang を起動した。

その後、application が起動する前に Erlang VM が終了した。

```text
{bad_heart_flag,false}
{heart_check_start_timeout,...}
...
erlinit: Erlang VM exited
```

原因は最初の PoC `rel/vm.args.eex` に `-heart false` を記述していたことだった。Erlang の `-heart` は
heart を有効にする flag であり、`false` を指定して無効化する形式ではない。Brain bring-up では
`-heart` 自体を省略することで修正する。

修正後に firmware を再ビルドした。

```text
Firmware UUID: offer-chalk (932a3365-d91b-5e35-eaeb-9b14bb004a22)
```

再生成した `.fw` をローカルで展開し、p2 の `/srv/erlang/releases/0.1.0/vm.args` を `debugfs` で
確認したところ、`-heart` は含まれていなかった。

### rebase 後の firmware overlay 修正

PR #41/#42 を含む `origin/main` へ rebase した後、更新された USB HOST/NCM script に合わせて
firmware generation を再確認した。この確認で packaging の不足が見つかった。生成した ext4 rootfs には
`/etc/erlinit.config` がある一方、`erlinit.config` が `--pre-run-exec` から実行する
`/usr/bin/enable_net` が含まれていなかった。

原因は、再利用する local System artifact が System package の `rootfs_overlay/` を materialize しておらず、
Brain 固有の `rel2fw.sh` も application 側で生成した overlay だけを追加していたことだった。

修正内容:

- `NervesSystemBrain.Platform` で package-level の `rootfs_overlay/` を
  `.nerves/reusable-system-artifact` にコピーする。
- `scripts/rel2fw.sh` で application overlay より前に `$NERVES_SYSTEM/rootfs_overlay` を追加し、
  System が所有する boot / network script を application より下の層に保つ。

rebase 後の firmware は正常に再ビルドできた。

```text
Firmware UUID: ring-visa (b0eca2a7-2e4d-5df1-c3e8-397f556454a9)
```

その `.fw` を展開して p2 を確認した結果:

- `/usr/bin/enable_net` が mode `0775` で存在する。
- `/usr/bin/enable_ethernet_gadget` が mode `0775` で存在する。
- `/srv/erlang/releases/0.1.0/vm.args` には引き続き `-heart` がない。
- `/usr/bin/enable_net` には rebase 後の PR #41/#42 の USB role logic が含まれる。

`ring-visa` firmware を準備済み SD card に書き込んだ。

```text
100% [====================================] 17.21 MB in / 268.44 MB out
Success!
```

`ring-visa` を boot すると、以前の heart failure を越えて Erlang/OTP 29 banner まで進んだが、
その後 device LCD 上では停止したように見えた。host 側に USB NCM interface は現れなかったが、
これは PR #41/#42 由来の host-mode DTB を SD boot partition が使っていたため、この時点では想定内だった。

次の iteration に向け、application に最小限の diagnostic launcher を追加した。

- `HelloKioskBrain.BootTrace` が `hello_kiosk:` marker を console に出し、
  `/root/hello_kiosk_boot.log` にも追記する。
- `HelloKioskBrain.KioskLauncher` が main application supervision tree 起動後に重い Kiosk display path を
  開始する。これにより display / NIF init が block しても、application の他の部分まで起動できる。

診断用 firmware は正常に再ビルドできた。

```text
Firmware UUID: earth-nut (48a0e2c9-346e-55f0-6337-aaf7a02d1dd8)
```

診断 boot では、`.fw` 書き込み後に `sd/use_usb_ncm.sh` で SD boot partition を peripheral DTB に
切り替える。LCD が console banner のままでも host 側から USB NCM / SSH を試せるようにするためである。

`earth-nut` を boot した結果、release から application が起動していることを確認できた。

```text
hello_kiosk: application start
hello_kiosk: starting supervisor children
hello_kiosk: kiosk launcher init ...
erlinit: Erlang VM exited
```

VM は3秒遅延の Kiosk task marker より前に終了したため、display / NIF path が原因である可能性は低くなった。
`rel/vm.args.eex` と upstream `circuits_quickstart` を比較したところ、release option が不足していた。
Elixir CLI は `-run elixir start_cli` で起動していたが、`-extra` の後に `--no-halt` を渡していなかった。
この console では CLI initialization 完了後、application が起動直後であっても VM が終了できてしまう。

修正として、標準 Nerves style の keepalive flag を追加した。

- `+Bc`
- `-noshell`
- `-extra --no-halt`

firmware を再ビルドした。

```text
Firmware UUID: skill-toe (c0e67534-715b-587d-a855-d481d89678b2)
```

展開した `.fw` の `/srv/erlang/releases/0.1.0/vm.args` に `--no-halt` が含まれること、
diagnostic module と System overlay が引き続き存在することを確認した。

`skill-toe` を PW-SH6 で boot すると成功し、Kiosk home screen まで到達した。画面では次を確認した。

- model: `PW-SH6`
- title: `Nerves on Brain`
- wired/NCM address: `10.42.0.2`
- display: `OK`
- touch: `OK`
- keyboard: `OK`
- network: `OK`
- runtime: `OTP 29 / Elixir 1.20.2`
- memory: `39 / 112 MB`
- battery: charging, `48%`

これにより、standard Nerves style の application release から既存の PW-SH6 boot/rootfs stack までの
PoC 経路が成立することを確認した。

```text
MIX_TARGET=brain mix firmware
  -> fwup complete task
  -> ext4 p2 rootfs
  -> erlinit
  -> Nerves release with ERTS
  -> hello_kiosk Brain UI
```

この時点の host-side check では、device UI が `usb0 10.42.0.2` を表示していたにもかかわらず、
USB NCM interface は確認できなかった。これは System dependency / firmware packaging PoC の blocker ではなく、
host / cable / USB enumeration の別 follow-up として扱う。

device を reboot し、Kiosk の `切替` button から USB mode を HOST に変更すると、PW-SH6 は local network 上で
`192.168.10.103` を取得した。ThinkPad からの host-side verification は成功した。

```text
PING 192.168.10.103: 3 packets transmitted, 3 received, 0% packet loss
```

on-device SSH daemon への SSH 接続も成功した。

```text
Interactive Elixir (1.20.2)

SHARP Brain PW-SH6
hello_kiosk_brain 0.1.0
Elixir 1.20.2 / OTP 29

iex(hello_kiosk_brain@brain)1>
```

これにより、device が HOST-mode network で到達可能な場合、standard release PoC でも既存 application SSH
path 経由で remote IEx を利用できることを確認した。IEx で `exit` と入力すると compile error になったが、
project の `quit` helper では SSH session を正常に終了できた。

成功した boot の後、`hello_kiosk` を standard Nerves application layout にさらに一段近づけた。

- `config/config.exs` から `:nerves_bootstrap` を起動し、`host.exs` または `target.exs` を import する形にした。
  `circuits_quickstart` と AtomCam2 example に近い構成である。
- Brain 固有の firmware config (`config :nerves, :firmware`) は `config/target.exs` に置く。
- target config に `config :shoehorn` metadata を置き、System の `erlinit.config` では `shoehorn.boot` を
  boot する。通常の Nerves application に近い形である。
- `BootTrace` と Kiosk launch delay は application config で制御し、bring-up diagnostics を code change
  なしで無効化できるようにした。
- `examples/hello_kiosk` は `BRAIN_SYSTEM_SOURCE` で System dependency source を切り替えられる。
  default は `local` とし、この branch の trial-and-error workflow に合わせる。`github` / `release` は
  将来の tagged System artifact test 用、`path` は `BRAIN_SYSTEM_PATH` で別 checkout を試すためのもの。
- System の `erlinit.config` を `--boot shoehorn` に変更し、upstream System と AtomCam2 に合わせた。
  その結果生成した firmware は PW-SH6 実機でも確認した。

### `shoehorn.boot` の PW-SH6 実機確認

`zebra-hello` firmware (`fc70a5d0-7b40-5649-ae66-3565d1bfadb2`、SHA-256
`fddc6db63e92a9021561a0cf54759a15eb82f10d9e2289e0c12689ff25397342`) を reference PW-SH6 で boot した。
KIOSK UI と HOST-mode network が起動し、device は `192.168.10.103` で応答した。

OTP SSH の direct-exec query では次を確認した。

```elixir
%{
  boot: {:ok, [[~c"/srv/erlang/releases/0.1.0/shoehorn"]]},
  hello_kiosk: ~c"0.1.0",
  node: :hello_kiosk_brain@brain,
  otp_release: ~c"29",
  shoehorn: ~c"0.9.3",
  started: true,
  system_architecture: ~c"arm-buildroot-linux-gnueabi"
}
```

これは firmware image 内の file 存在から推測したのではなく、実際の VM boot argument を確認したものになる。
そのため `--boot shoehorn` を PoC の default として採用する。release に `shoehorn.boot` がない場合の
legacy normal-release fallback は `erlinit` 側に残す。

### repository root の OTP version 固定

standard Nerves task を System repository root から直接実行すると、root 側は host OTP 28 を継承し、
再利用する target System 側は OTP 29 という不一致が表面化した。host と target の OTP major version が
異なるため、Nerves が environment を拒否した。

repository root に `examples/hello_kiosk` と同じ `.tool-versions`
(`erlang 29.0.5`, `elixir 1.20.2-otp-29`) と root `mix.lock` を追加した。これにより root-level の
System package / artifact operation でも application / target と同じ BEAM format contract を使用する。

### portable System artifact の生成と利用

最初に root で `mix nerves.artifact` を実行すると、adapter boundary がもう1つ見つかった。
`archive/3` が `Nerves.System.BR` へ delegate していたため、通常の Buildroot tree を
`.nerves/artifacts/...` 以下に期待していた。一方、再利用 adapter は
`.nerves/reusable-system-artifact` を materialize していた。

`NervesSystemBrain.Platform.archive/3` は、standard `nerves_system_br` System archive の形に合わせて
次を行うようにした。

- 実際の target sysroot を `staging/` にコピーする。top-level の `o/staging` link だけを follow し、
  sysroot 内部の symlink は保持する。
- `images/` と共通 Nerves environment / scripts を含める。
- Brain の `rel2fw.sh`、`fwup.conf`、`rootfs_overlay` を overlay する。
- System artifact に host toolchain を含めないため、`o/host` は除外する。

standard task により次を生成した。

```text
nerves_system_brain-portable-0.1.0-791B5D1.tar.gz  90 MiB
```

archive をこの checkout 外の `/tmp` に展開した。`NERVES_SYSTEM` をその展開先へ設定した状態で、
`hello_kiosk` の forced ARM target compile と `MIX_ENV=prod mix firmware` が完了した。
firmware build log では展開済み artifact から System overlay を copy し、firmware nickname
`emotion-nasty` (`548e7b25-b567-519e-2e41-a636838c2d1d`) を生成した。

これにより System artifact 自体が portable であることを確認した。この時点では cached
`nerves_toolchain_brain` がこの checkout の `o/host` を参照する link のままだったため、次の実験を行った。

### toolchain artifact の生成と利用

`NervesToolchainBrain.archive/3` は、再利用する `o/host` tree 全体を host-specific な standard Nerves
`.tar.xz` として package する。archive root は `nerves_toolchain_brain/`、symlink は保持し、Buildroot
output を変更せずに `VERSION` を `nerves-toolchain.tag` として含める。

standard task により次を生成した。

```text
nerves_toolchain_brain-linux_x86_64-0.1.0-380F8C4.tar.xz  197 MiB
SHA-256 2a7a525b8302833d69d2dc8f48f9a88ff68e30fa28be203582334da2aaab358f
```

`/tmp` に展開した toolchain の compiler は、移動後の path から次を返した。

```text
arm-linux-gcc.br_real (Buildroot 2021.11-18033-g83947c7bb6) 14.3.0
arm-buildroot-linux-gnueabi
```

consumer test の前に、以前生成した NIF と `devmem` output を削除した。`NERVES_SYSTEM` と
`NERVES_TOOLCHAIN` をそれぞれ `/tmp` に展開した artifact へ向けると、build log には次が出た。

```text
/tmp/nerves-toolchain-brain-consumer/nerves_toolchain_brain/bin/arm-linux-g++
  --sysroot /tmp/nerves-system-brain-consumer/.../staging
  -I/tmp/nerves-system-brain-consumer/.../staging/usr/lib/erlang/erts-17.0.5/include
  -marm -mcpu=arm926ej-s -mfloat-abi=soft
```

NIF と static helper は再ビルドされ、`mix firmware` は `dynamic-labor`
(`4f7a7ade-89c9-560e-10aa-6b3921e7e649`) を生成した。これにより repository の `o/host` / `o/staging`
path を使わず、standard Nerves cross-compilation が成立することを確認した。

`toolchain/` も System package checksum に含まれるため、最終 System artifact 名は
`nerves_system_brain-portable-0.1.0-E7EEC96.tar.gz` (SHA-256
`2022f564fb774dd0923f39a614f335f76844f4ea6001f0490b1ebc1db515e86d`) になった。
その内容を実際に利用した artifact と比較し、同一であることを確認した。

### standard artifact resolution の確認

最初に isolated cache で `BRAIN_SYSTEM_SOURCE=local` を試したところ、archive は利用されなかった。
これは想定どおりである。この development mode は `nerves: [compile: true]` を指定するため、Nerves は
local package を再ビルドし、`.nerves/reusable-system-artifact` と `o/host` への link を cache する。

そこで repository 外に使い捨ての Nerves application を作り、同じ local System package source を
使いつつ `compile: true` は付けなかった。tagged dependency の artifact behavior に相当する構成である。
空の `NERVES_ARTIFACTS_DIR`、`NERVES_SYSTEM` / `NERVES_TOOLCHAIN` override なし、isolated
`NERVES_DL_DIR` の状態で `mix deps.get` を実行すると次の結果になった。

```text
Checking for prebuilt Nerves artifacts...
  Checking nerves_system_brain...
  => Trying .../nerves_system_brain-portable-0.1.0-087E263.tar.gz
  => Success
  Checking nerves_toolchain_brain...
  => Trying .../nerves_toolchain_brain-linux_x86_64-0.1.0-380F8C4.tar.xz
  => Success
```

isolated artifact cache には、この repository への link ではなく、実体のある展開済み directory が入った。
`MIX_TARGET=brain mix compile` も成功した。これにより archive name、root、checksum、extract、通常の
Nerves resolver path を確認できた。未実施なのは GitHub release への公開だけである。

### standard `mix firmware.burn` task の確認

physical media を壊すリスクを避けるため、standard task を disk image に対して確認した。

```sh
MIX_ENV=prod MIX_TARGET=brain mix firmware.burn \
  --device /tmp/hello_kiosk_brain-burn-test.img --task complete -y
```

firmware `pig-abandon` (`b904b08d-d8e1-5a87-000b-3dd24f59e84a`) を再ビルドし、fwup write まで
完了した。生成された 321 MiB image は想定した MBR を持っていた。

```text
partition 1: start 2048,   131072 sectors, 64 MiB, FAT32 LBA, bootable
partition 2: start 133120, 524288 sectors, 256 MiB, Linux
```

これにより System dependency、firmware generation、`fwup`、standard burn task は、A/B slot を導入せず
採用できることを確認した。ただしこの時点の `complete` task は p1 layout を作成・維持するものの、
brain-hackers boot file を package していなかったため、blank media を単独で bootable にはできなかった。
blank-media policy が決まるまでは、pre-provisioned p1 が前提だった。

application compile に残っていた warning は Nerves System packaging PoC とは無関係だった。

- `HelloKioskBrain.Input` の `touch_btn/2` clause が連続していない warning
- `HelloKioskBrain.Fb.stamp/4` の bitstring size variable pinning warning
- `HelloKioskBrain.Battery` の未使用 `@battmon`
- `HelloKioskBrain.Display` が未定義の `HelloKioskBrain.Fb.open/0` を呼ぶ warning。
  `Display` は現在 supervise されておらず、実際に動いている Kiosk path は `HelloKioskBrain.Kiosk` を使う。

### target IEx の標準 dependency

example application を、通常の Nerves example が使う最小構成に合わせた。

- `:nerves_runtime` を target dependency と shoehorn init application にする。
- `:nerves_motd` が `priv/iex.exs` から target summary を表示する。
- `:toolshed` を `priv/iex.exs` から import する。
- project 固有 IEx helper は standard helper の後に import する。

`nerves_runtime` の追加により、standalone application では不要だった System responsibility が1つ見つかった。
`nerves_uevent` は `libmnl` に link するため、最初の target compile は `libmnl/libmnl.h` 不足で失敗した。
`BR2_PACKAGE_LIBMNL=y` を `nerves_defconfig` に追加すると header / library が System sysroot に入り、
shared library も target rootfs に配置された。System output を再ビルドした後、standard application command で
全 dependency と ARMv5 向け native uevent helper の compile が成功した。

```sh
MIX_TARGET=brain BRAIN_SYSTEM_SOURCE=local mise exec -- mix compile
```

`sphere-laptop` firmware の production release には `nerves_runtime 0.13.13`、`nerves_motd 0.1.17`、
`toolshed 0.5.0`、`nerves_uevent 0.1.7` が含まれる。host test は4件すべて pass した。x86_64 上で
ARM32 kiosk NIF を load できないことによる想定内 warning は残る。新しい runtime initialization と
IEx startup の device verification が次の確認項目だった。

### 現在の single-root layout では `mix upload` は安全ではない

現在の application には `mix upload` task がない。この task は通常 `ssh_subsystem_fwup` から、一般には
`nerves_ssh` 経由で提供され、firmware を `fwup` という SSH subsystem に送る。Brain application の
custom SSH daemon は当時 SFTP だけを公開していた。

task と subsystem を追加すること自体は容易だが、それだけでは update が安全にはならない。standard
subsystem は target 側の `fwup` を `--no-unmount` と firmware の `upgrade` task で実行する。
reference PW-SH6 を read-only SSH で調べると次を確認した。

```text
kernel command line: root=/dev/mmcblk1p2 rw rootwait
root mount:          /dev/root / ext4 rw
target fwup:         /usr/bin/fwup
```

現在の `complete` task は p2 全体へ ext4 image を書き込み、destination が unmount されていることを前提とする。
`upgrade` task は意図的に error を返す。`complete` を remote から再利用すると、Erlang と `fwup` 自身が
実行中の mounted root filesystem を上書きすることになる。

そのため `mix upload` は、現在動作している standard application compile / firmware build flow とは独立した
storage / update の follow-up とする。安全な設計には、boot selection / rollback を持つ A/B rootfs か、
p2 を unmount した状態で image を適用する recovery / staging environment が必要である。
SFTP で application release だけを置換する方式は別途作れるが、standard Nerves の `mix upload` firmware
protocol とは異なる。

### System dependency 化は可能

`nerves_system_brain` は、最初の段階では `nerves_defconfig`、`Config.in`、`rootfs_overlay` を変更せずに
通常の Nerves System package に近い形へできる。package surface と platform 固有の boot/storage choice は
分離できることが重要である。

現在再利用している Buildroot output には `nerves_system_br` が期待する directory が存在する。

- `o/host`
- `o/staging`
- `o/images`

`nerves_system_br` の environment setup は、toolchain を `host`、sysroot / ERTS header を `staging` から
見つけられるため、この構成をそのまま local provider として利用できる。

### ARMv5 / Bootlin toolchain は Nerves interface から提供できる

local development では既存 Bootlin toolchain を `o/host` から再利用できる。想定する Nerves
cross-compile variable は次のように対応する。

| 変数 | 想定値 |
| --- | --- |
| `TARGET_ARCH` | `arm` |
| `TARGET_CPU` | `arm926ej_s` |
| `TARGET_OS` | `linux` |
| `TARGET_ABI` | `gnueabi` |
| `TARGET_GCC_FLAGS` | `-marm -mcpu=arm926ej-s -mfloat-abi=soft` |

特に慎重に確認すべき値は `TARGET_CPU` である。Buildroot は `BR2_arm926t` を選択する一方、GCC は
i.MX283 core family により近い `-mcpu=arm926ej-s` を受け付ける。この指定が compiler / package regression を
起こす場合は、より単純な Buildroot-selected default に戻し、CPU detail は metadata だけに残す。

release use では dedicated `nerves_toolchain_brain` artifact を公開することが望ましい。これにより application
developer が full Buildroot output tree を local に持つ必要がなくなる。

### native code は Nerves cross compilation に寄せられる

既存の `examples/hello_kiosk/Makefile` は、全体として適切な contract を持っている。

- `CC` / `CXX` を environment から渡せる。
- `ERTS_INCLUDE_DIR` を environment から渡せる。
- `MIX_APP_PATH` で `priv/` artifact の出力先を制御できる。

これは Nerves + `elixir_make` と相性がよい。Nerves environment が読み込まれれば、application 自身が
`o/host/bin/arm-linux-g++` を探索する必要はなくなる。

### `mix compile` と `fwup` は分離して検証できる

`nerves_system_brain` を dependency として利用し target-specific native code を compile するだけなら、
`fwup` は不要である。Nerves firmware artifact を生成または burn するときに `fwup` が必要になる。

storage layout を変えずに最初の firmware generation step が成立することは確認できた。

- `fwup.conf` は既存の FAT p1 + Linux p2 layout を表現する。
- `scripts/rel2fw.sh` は Nerves firmware task interface を保ちながら、stock squashfs merge の代わりに
  `rootfs.tar`、target release、generated rootfs overlay から ext4 image を作る。
- `complete` task は p2 を書き込み、同じ partition offset を維持する。この時点では p1 に
  brain-hackers boot file が既にあることを前提としており、blank SD を一から作る既存 base-image workflow の
  replacement ではなかった。

このため migration は段階的に進められる。

1. 既存 `o/` output を使って `MIX_TARGET=brain mix compile` を成立させる。PoC で完了。
2. `Nerves.Release.erts/0` で release を作る。PoC で完了。
3. 現在の p2 layout 向け ext4-rootfs `.fw` を作る。PoC で完了。
4. known-good p1 boot file を持つ SD card で `.fw` を device test する。PW-SH6 の `skill-toe` で完了。
5. 現在の `complete` task で pre-provisioned media に `mix firmware.burn` を使う。blank-media boot file、
   A/B slot、update architecture は独立した follow-up とする。

### PW-SH6 固有部分は System interface より下に残す

標準化のために削除しないもの:

- brain-hackers の U-Boot / kernel asset。
- 最初の段階では FAT p1 + ext4 p2 storage layout。
- ARMv5 soft-float constraint。
- display / input initialization と device-specific kernel interface。
- `fwup` が experimental な間の manual SD deployment script。

## 今後の課題

- consume-test 済みの `nerves_toolchain_brain` と `nerves_system_brain` artifact を tagged GitHub release に
  publish し、`BRAIN_SYSTEM_SOURCE=github MIX_TARGET=brain mix deps.get` を確認する。
- native package test 後、`TARGET_CPU` を `arm926ej_s`、`arm926t`、または compiler flag から省略するか決める。
- Brain app に diagnostic `BootTrace` / `KioskLauncher` scaffolding を残すか、normal supervision に戻すか、
  bring-up config flag で gate するか決める。
- peripheral-mode USB development が引き続き必要なら USB NCM host enumeration を調査する。
  HOST-mode LAN networking と SSH/IEx は確認済み。
- `mix firmware.burn` の blank-media path を用意する。boot file 再配布が可能なら p1 asset を package し、
  そうでなければ base-image prerequisite を文書化する。
- PoC verification 後に ADR 0005 を再確認し、採用する変更をより小さい implementation issue に分割する。

## 2026-09-21: blank SD provisioning と A/B 調査

固定して使用する buildbrain release は `2026-03-25-024518` とした。direct-SD boot path には release の
小さい asset だけで十分であり、685 MiB の base SD image を download する必要はない。必要な file は次のとおり。

| ファイル | アーカイブ | SHA-256 確認済みアーカイブ |
| --- | --- | --- |
| `edsh6exe.bin` | `uboot-sh6-2026-03-25-024518.zip` | `a07b43ade594b566ed189bcfc5e49212006679600ca30e2fb7468961ef664f95` |
| `zImage` | `linux-2026-03-25-024518.zip` | `da7a8f87c6daf982085c2f7042d874654645a28a6318558d3c6ea0e6a2851f69` |
| `imx28-pwsh6.dtb` | `linux-2026-03-25-024518.zip` | 同上 |

`scripts/fetch_boot_assets.sh` でこれらを検証して展開する。`fwup.conf` は p1 を FAT32 で format し、label を
`boot` に設定して3ファイルを書き込み、p2 に生成済み ext4 release image を書くようにした。
complete firmware を raw image に展開して physical media を使わず確認した。

```text
p1: FAT32 BOOT, edsh6exe.bin, zImage, imx28-pwsh6.dtb
p2: ext4, /srv/erlang/releases/0.1.0/shoehorn.boot
```

固定 U-Boot source revision は `e8fc0d0cf39d9cd06245ef1777d1cf54258e5cb6`。
`brain_mx28_common.h` は p1 から `uEnv.txt` を読み込み、`bootcmd` より前に import するため、`sdroot` で
`/dev/mmcblk1p2` または p3 を選択できる。一方で bootcount、slot validation、rollback、inactive-slot updater は
提供されていない。単に p3 partition を追加するだけでは remote update はむしろ安全でなくなる。
そのため ADR 0007 では legacy script を recovery tooling として残し、A/B / `mix upload` は boot selection と
rollback を一体で設計・実機検証するまで保留とした。
