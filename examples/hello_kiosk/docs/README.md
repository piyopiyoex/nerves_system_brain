# hello_kiosk ドキュメント

`hello_kiosk` の **現在の判断** と **調査・作業の履歴** を分けて管理する。

- [`adr/`](adr/): 現在の実装方針や、今後も前提にする実機知見
- [`worklog/`](worklog/): 提案、実験、レジスタ dump、報告、手順、引き継ぎなどの時系列記録
- [`worklog/assets/`](worklog/assets/): worklog から参照する画像などの補助ファイル

まず ADR を読み、根拠や調査経緯が必要なときだけ worklog をたどる。worklog に残る
「未着手」「次にやる」などの記述は作成時点の記録であり、現在の TODO を意味しない。

## 現在の要点

| 領域 | 現在の理解・方針 | ADR |
|---|---|---|
| 描画 | LovyanGFX を NIF 経由で利用する | [0001](adr/0001-LovyanGFX_NIF移植.md) |
| タッチ音 | オンボード PWM ブザー経路は使わない | [0002](adr/0002-タッチ音_PWM調査結論.md) |
| バックライト | 独立 ON/OFF・調光は行わない | [0003](adr/0003-バックライト制御線_調査結論.md) |
| オンボード音声 | 現行 DTB の SGTL5000 定義を正しい前提にしない | [0004](adr/0004-音声_DTBと実機I2C不一致.md) |
| 電源 OFF | 5V 接続中の真の電源断を前提にしない | [0005](adr/0005-電源OFF_5V接続中.md) |
| 音声 | 必要な場合は USB オーディオを主経路とする | [0006](adr/0006-USBオーディオを採用する.md) |
| WiFi / BLE | Brain 自身に載せるなら kernel 再ビルドを行う。必須機能ではない | [0007](adr/0007-USB無線_カーネル再ビルド方針.md) |

### ネットワークについて

現在の `nerves_system_brain` の標準開発経路は USB-NCM。USB host + USB-Ethernet + DHCP/NTP も
実機で成立しているが、同じ microUSB ポートの gadget/host は排他的である。有線 LAN の検証は
[実施記録](worklog/20260905_有線LAN化_USBホスト_実施記録.md)を参照する。

## ADR の読み方

example 側の ADR は、アプリケーションの設計判断だけでなく、後続の実装判断で繰り返し参照する
**確定した実機知見**も記録する。詳細な実験手順や dump は ADR から worklog へ分離している。
「採用」は判断が決まったことを表し、機能実装や実機検証の完了を必ずしも意味しない。

## 作業記録

時系列の記録一覧は [`worklog/README.md`](worklog/README.md) を参照する。
