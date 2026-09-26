defmodule HelloKioskBrain.Native do
  @moduledoc """
  KIOSK の既存描画 API を `LovyanGFX` へ接続する薄い adapter。
  """

  @display_options [
    width: 854,
    height: 480,
    framebuffer: "/dev/fb0",
    framebuffer_mode: :buffered_rgb565,
    swap_bytes: true
  ]

  @doc "パネルとオフスクリーンキャンバスを初期化する。:ok | :error"
  def init_display, do: LovyanGFX.start(@display_options)

  @doc "nested list を含む描画コマンド列を 1 フレームとして描画する。"
  def render(commands) when is_list(commands),
    do: commands |> List.flatten() |> LovyanGFX.render()

  @doc "LovyanGFX MovingIcons デモを背景スレッドで開始。:ok | :already_started | :error"
  def start_moving_icons, do: LovyanGFX.Examples.MovingIcons.start(@display_options)

  @doc "MovingIcons デモを停止。:ok"
  def stop_moving_icons, do: LovyanGFX.Examples.MovingIcons.stop()
end
