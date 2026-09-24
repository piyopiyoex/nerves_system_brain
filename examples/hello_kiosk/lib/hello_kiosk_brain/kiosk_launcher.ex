defmodule HelloKioskBrain.KioskLauncher do
  @moduledoc false

  use GenServer

  @default_delay_ms 0

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    delay_ms = Keyword.get(opts, :delay_ms, configured_delay_ms())

    HelloKioskBrain.BootTrace.log("kiosk launcher init delay_ms=#{delay_ms}")
    Process.send_after(self(), :start_kiosk, delay_ms)
    {:ok, %{task: nil}}
  end

  @impl true
  def handle_info(:start_kiosk, state) do
    HelloKioskBrain.BootTrace.log("kiosk launcher start requested")

    {:ok, task} =
      Task.start(fn ->
        HelloKioskBrain.BootTrace.log("kiosk task before Kiosk.start_link")
        result = HelloKioskBrain.Kiosk.start_link([])
        HelloKioskBrain.BootTrace.log("kiosk task Kiosk.start_link returned #{inspect(result)}")
      end)

    {:noreply, %{state | task: task}}
  end

  def handle_info(message, state) do
    HelloKioskBrain.BootTrace.log("kiosk launcher message #{inspect(message)}")
    {:noreply, state}
  end

  defp configured_delay_ms do
    Application.get_env(:hello_kiosk_brain, :kiosk_start_delay_ms, @default_delay_ms)
  end
end
