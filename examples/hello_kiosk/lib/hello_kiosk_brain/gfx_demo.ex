defmodule HelloKioskBrain.GfxDemo do
  @moduledoc """
  Minimal check that the LovyanGFX NIF (kiosk_nif.so) loads via @on_load at
  boot and can draw. Uses HelloKioskBrain.Native (papapa-style NIF) +
  HelloKioskBrain.Draw (command DSL). Draws one Japanese frame, then starts
  the Moving Icons demo in the NIF's background thread.
  """
  use GenServer
  require Logger

  alias HelloKioskBrain.{Native, Draw}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    {:ok, %{}, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    unbind_fbcon()

    case Native.init_display() do
      :ok ->
        Logger.info("GfxDemo: init_display ok")
        draw_japanese()
        Process.sleep(2000)
        Native.start_moving_icons()
        Logger.info("GfxDemo: moving icons started")

      other ->
        Logger.error("GfxDemo: init_display => #{inspect(other)}")
    end

    {:noreply, state}
  rescue
    e ->
      Logger.error("GfxDemo crashed: #{inspect(e)}")
      {:noreply, state}
  end

  defp draw_japanese do
    cmds = [
      Draw.clear(0x00182F),
      Draw.text(40, 60, "tl", "jp24", 0xFFA500, "日本語テスト: シャープ ブレイン"),
      Draw.text(40, 120, "tl", "jp24", 0xFFFFFF, "LovyanGFX NIF on Nerves / PW-SH6"),
      Draw.rect(40, 180, 200, 80, 0x50DC78),
      Draw.circle(400, 300, 60, 0xFF5A5A)
    ]

    Native.render(cmds)
  end

  defp unbind_fbcon do
    for dir <- Path.wildcard("/sys/class/vtconsole/vtcon*"),
        File.read!(dir <> "/name") =~ "frame buffer" do
      File.write!(dir <> "/bind", "0")
    end
  rescue
    _ -> :ok
  end
end
