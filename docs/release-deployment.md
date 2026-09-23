# アプリケーション release / firmware の作成と配置

`nerves_system_brain` は PW-SH6 向けの実行環境と release の配置先を提供し、
アプリケーション固有のソースコードやビルド処理には依存しない。
現在は Nerves 標準寄りの firmware 生成フローと、従来の ERTS 非同梱 release 配備フローを
併存させている。

## Nerves firmware フロー

`examples/hello_kiosk/` は `nerves_system_brain` を通常の System dependency として参照し、
`MIX_TARGET=brain` で target release と firmware を生成できる。

```sh
cd examples/hello_kiosk
export MIX_TARGET=brain

mise exec -- mix deps.get
mise exec -- mix firmware
```

repository 内の example は `../..` の checkout を local path dependency として使う。
System / toolchain package の公開後は version dependency へ置き換え、application 側の通常の
Nerves workflow は変えない。

この経路では `Nerves.Release.erts/0` により ERTS を release に同梱し、`mix firmware` が
`examples/hello_kiosk/_build/brain_<env>/nerves/images/hello_kiosk_brain.fw` を生成する。
`.fw` は既存の FAT p1 + ext4 p2 レイアウトを維持する。`complete` task は p1 を FAT32 として
初期化し、fixed buildbrain release から取得・checksum 検証した direct-SD boot files と、p2 の
ERTS 同梱 ext4 rootfs を書き込む。そのため blank SD の初回 provisioning に利用できる。

microSD へ書き込む場合は、application directory から通常の Nerves task を使う。

```sh
mise exec -- mix burn
```

実デバイスに触れず disk image を作って `complete` task を検証する場合は、低レベル task を明示できる。

```sh
mise exec -- mix firmware.burn \
  --device /tmp/hello_kiosk_brain.img --task complete -y
```

この経路で MBR、64 MiB の FAT p1、256 MiB の ext4 p2 が生成されることを確認済み。raw image の
p1 に `edsh6exe.bin`、`zImage`、active の `imx28-pwsh6.dtb`、HOST / NCM の参照 DTB があることと、
p2 の release は検査済みである。fresh burn では HOST を active にする。
blank SD での実機 boot は次の確認項目であり、失敗時の復旧には旧 deployment path を使用する。

`hello_kiosk` は標準 SSH 実装として `NervesSSH` を使うため fwup SSH subsystem も依存関係に含まれる。
ただし現在の `fwup.conf` の `upgrade` task は安全のため明示的に失敗するので、`mix upload` / OTA update は
まだサポート対象ではない。初回 provisioning は `mix burn` を使う。

## legacy release 配備フロー

`sd/populate_sd.sh` と `sd/deploy_release.sh` は、既存 media の再構築や recovery のために残す
legacy path である。通常の initial provisioning では、firmware 内に release を含めるため不要である。
標準化 branch では独自 `SshDaemon` を削除しているため、この legacy release path は SSH を含む完全な
feature parity ではなく、主に rootfs / application の切り分けと recovery 用として扱う。

## 責務の分担

### System 側

`nerves_system_brain` は次を担当する。

- PW-SH6 向け Buildroot rootfs の構築
- ARMv5 用 Erlang/ERTS の構築と `/usr/lib/erlang` への配置
- release の配置先 `/srv/erlang` の提供
- `erlinit` による `/srv/erlang` の release 起動
- target 向け Buildroot staging tree と cross toolchain の生成
- 完成済み release を SD カードへ配置する `sd/deploy_release.sh` の提供

### アプリケーション側

アプリケーションは次を担当する。

- アプリケーション本体、設定、静的資産の管理
- System の Erlang/OTP と互換性のある release の作成
- release が必要とする OTP application の target 互換性の確保
- NIF や native helper を含む場合の ARMv5 向け cross compile
- アプリケーション固有の実機確認
- 初回配置後の更新方法の選択

System はアプリケーションの release をビルドしない。また、`deploy_release.sh` は
依存関係の解決や native code の cross compile を行わない。

## release の要件

`deploy_release.sh` に渡すディレクトリは、`mix release` などで作成した完成済みの
release で、少なくとも `releases/` ディレクトリを含む必要がある。

旧配備フローでは System が target 用 ERTS を提供するため、アプリケーションの release には
ERTS を含めない。

```elixir
releases: [
  application: [
    include_erts: false
  ]
]
```

BEAM bytecode は基本的に CPU architecture に依存しないが、ERTS、NIF、native helper、
native library は target に依存する。PW-SH6 は ARM926EJ-S / ARMv5TEJ soft-float であるため、
これらを release に含める場合は System の target 環境と互換になるようにビルドする。

また、ERTS を含めない release であっても、release が参照する OTP application は
`/srv/erlang` 以下の release から利用できる状態にする必要がある。必要に応じて
`nerves_system_brain` の Buildroot staging tree を release 構築時に利用する。

同梱の `examples/hello_kiosk/` はこの構成例であり、System の ARMv5 OTP staging tree と
cross toolchain を利用して target 用 release を作成している。これは例示であり、
`nerves_system_brain` 自体が `hello_kiosk_brain` に依存することを意味しない。

## SD カードへの配置

`sd/deploy_release.sh` に SD カードのディスク全体と release ディレクトリを指定する。

```sh
sudo bash sd/deploy_release.sh /dev/sdX /path/to/release
```

スクリプトは対象ディスクと rootfs パーティションを確認した後、既存の `/srv/erlang` を
指定した release で置き換える。SD カード上の release を完全に入れ替える処理なので、
初回配置だけでなく release 全体を更新するときにも利用できる。

アプリケーション名は deployment interface の一部ではない。release 名にかかわらず、
同じ `DEVICE RELEASE_DIR` の形式で配置する。

配置後は PW-SH6 実機で release の起動とアプリケーション機能を確認する。
