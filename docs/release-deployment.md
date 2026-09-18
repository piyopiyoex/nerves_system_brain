# アプリケーション release の作成と配置

`nerves_system_brain` は PW-SH6 向けの実行環境と release の配置先を提供し、
アプリケーション固有のソースコードやビルド処理には依存しない。
アプリケーションは完成した Elixir release を用意し、`sd/deploy_release.sh` で
SD カードの `/srv/erlang` へ配置する。

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

現在の PW-SH6 構成では System が target 用 ERTS を提供するため、アプリケーションの
release には ERTS を含めない。

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
