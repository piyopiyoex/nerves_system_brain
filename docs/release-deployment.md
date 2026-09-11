# アプリケーション release の作成と配置

PW-SH6 固有のシステム構築処理は、アプリケーションのソースコードやビルド処理に
依存しない。アプリケーションは Elixir release として別途作成し、完成した release
ディレクトリを SD カードへ配置する。

## 責務の分担

システム側は次の項目を担当する。

- PW-SH6 向け rootfs と OTP の構築
- OTP の `/usr/lib/erlang` への配置
- release の配置先 `/srv/erlang` と `erlinit` による起動
- USB NCM など、起動に必要な機器固有の設定

アプリケーション側は次の項目を担当する。

- アプリケーション本体、設定、静的資産の管理
- システムに搭載する OTP と互換性のある release の作成
- NIF や外部実行ファイルを含む場合の ARMv5 向けクロスビルド
- アプリケーション固有の実機確認

## release の要件

release は `mix release` などで作成し、`releases/` を含むディレクトリを用意する。
システム側が OTP を提供するため、Mix プロジェクトでは release に ERTS を含めない。

```elixir
releases: [
  application: [
    include_erts: false
  ]
]
```

release に必要な OTP アプリケーションがすべて含まれていることも、アプリケーション側で
保証する。NIF や外部実行ファイルは BEAM ファイルと異なり機種に依存するため、
PW-SH6 の ARMv5TEJ soft-float 環境に合わせてビルドする必要がある。

## SD カードへの配置

`sd/deploy_release.sh` に SD カードのディスク全体と release ディレクトリを指定する。

```sh
sudo bash sd/deploy_release.sh /dev/sdX \
  /path/to/application/_build/prod/rel/application
```

スクリプトは対象機器と第2パーティションを確認した後、release の内容を
`/srv/erlang` へコピーする。既存の `/srv/erlang` は確認後に置き換えるため、
初回配置または内容をすべて更新する場合に使用する。

このスクリプトはアプリケーションのビルド、依存関係の解決、NIF のクロスビルドを
行わない。これらを完了した release ディレクトリを指定する。

配置後の release 起動とアプリケーション機能は PW-SH6 実機で確認する必要がある。
