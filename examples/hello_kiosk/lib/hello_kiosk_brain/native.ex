defmodule HelloKioskBrain.Native do
  @moduledoc """
  KIOSK 描画 NIF(`priv/kiosk_nif.so`)のローダ。

  LovyanGFX を Linux フレームバッファ(/dev/fb0)へ描画する薄ラッパ。
  Elixir 側が組み立てた描画コマンド列(`HelloKioskBrain.Draw` 参照)を
  `render/1` でまとめて渡すと、オフスクリーンキャンバスへ描画後に
  パネルへ一括転送される。
  """

  @on_load :load_nif

  def load_nif do
    path = :filename.join(:code.priv_dir(:hello_kiosk_brain), ~c"kiosk_nif")
    :erlang.load_nif(path, 0)
  end

  @doc "パネルとオフスクリーンキャンバスを初期化する。:ok | :error"
  def init_display, do: :erlang.nif_error(:nif_not_loaded)

  @doc "描画コマンド列(iodata)を 1 フレームとして描画する。:ok | :error"
  def render(_iodata), do: :erlang.nif_error(:nif_not_loaded)

  @doc "LovyanGFX MovingIcons デモを背景スレッドで開始。:ok | :already_started | :error"
  def start_moving_icons, do: :erlang.nif_error(:nif_not_loaded)

  @doc "MovingIcons デモを停止。:ok"
  def stop_moving_icons, do: :erlang.nif_error(:nif_not_loaded)
end
