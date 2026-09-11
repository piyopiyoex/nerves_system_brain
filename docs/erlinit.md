# PW-SH6 の erlinit 設定

## 現在の方針

`rootfs_overlay/etc/erlinit.config` は、PW-SH6 の実機 bring-up を優先した現在の標準設定である。
起動ログ、LCD コンソール、異常終了後の調査用シェルは残しているが、いずれも用途を明示した上で
意図的に有効にしている。

各 option の仕様は、現在使用している
[erlinit v1.15.1](https://github.com/nerves-project/erlinit/tree/v1.15.1#configuration-and-command-line-options)
を基準とする。

通常運用用の別設定はまだ設けない。hardware bring-up 中に設定を分岐すると、実機で
使用した構成が不明確になるためである。通常運用へ移行するときは、後述する bring-up 用項目を
実機で確認しながら取り除く。

## 設定項目

| 設定 | 区分 | 目的 |
|---|---|---|
| `-v` | bring-up | `erlinit` の詳細な起動情報をカーネルログに出力する |
| `-c tty1` | bring-up / 実機固有 | LCD の fbcon と内蔵キーボードを Erlang コンソールに使用する |
| `--warn-unused-tty` | bring-up | カーネルログが Erlang コンソールではない tty に出ている場合に警告する |
| `LANG`, `LANGUAGE` | 通常動作 | UTF-8 ロケールと表示言語を設定する |
| `ERL_INETRC` | 通常動作 | Nerves の名前解決設定 `/etc/erl_inetrc` を Erlang に指定する |
| `ERL_CRASH_DUMP`, `ERL_CRASH_DUMP_SECONDS` | 障害解析 | crash dump の出力先を指定し、出力時間を 5 秒に制限する |
| `-m configfs:...` | USB NCM に必須 | USB NCM の初期化に必要な configfs をマウントする |
| `-r /srv/erlang` | 通常動作 | application release の検索場所を明示する |
| `--pre-run-exec /usr/bin/enable_ethernet_gadget` | USB NCM に必須 | Erlang 起動前に USB NCM の初期化スクリプトを同期実行する |
| `--run-on-exit /bin/sh` | bring-up | Erlang の異常終了時に調査用の `/bin/sh` を起動する |

`--run-on-exit` は Erlang が意図せず終了した場合だけ実行される。`/bin/sh` を終了すると、`erlinit` の
既定動作に従ってシステムは再起動する。

## 起動の流れ

1. Linux kernel が `/sbin/init` として `erlinit` を起動する。
2. `erlinit` が設定を読み込み、擬似ファイルシステムと `tty1` を準備する。
3. `erlinit` が `/tmp`、`/run` と追加指定した configfs をマウントする。
4. `erlinit` が `/srv/erlang` の release を検索し、Erlang VM の実行環境を準備する。
5. `erlinit` が `/usr/bin/enable_ethernet_gadget` を実行し、終了を待つ。
6. USB NCM 初期化スクリプトが configfs の gadget、UDC との接続、`usb0` の IP アドレスを設定する。
7. `erlinit` が Erlang VM を起動する。
8. Erlang VM が異常終了した場合は `/bin/sh` を起動し、その終了後に再起動する。

`erlinit` の責務は configfs のマウントと初期化スクリプトの実行順序までである。USB 識別情報、
MAC アドレス、IP アドレス、UDC の待機は `enable_ethernet_gadget` が管理する。application の
supervision tree から USB NCM を初期化しない。

使用中の `erlinit` v1.15.1 では、`--pre-run-exec` の終了状態にかかわらず Erlang の起動処理へ
進む。USB NCM の障害は初期化スクリプトの出力を確認し、`/root/gadget_diag.log` が生成されて
いる場合はその内容も確認する。

## 通常運用へ移行するときの候補

次の変更は、現在の bring-up が完了してから検討する。

- `-v` と `--warn-unused-tty` を削除し、起動時の出力を減らす。
- `--run-on-exit /bin/sh` を削除し、Erlang の異常終了時に既定どおり再起動する。
- 本体だけでの障害調査が不要になった場合は、`-c tty1` を維持するか再検討する。

configfs のマウントと `--pre-run-exec` は USB NCM に必要なため、通常運用でも維持する。
これらの変更は起動順序と障害調査手段に影響するため、PW-SH6 実機で確認してから行う。
