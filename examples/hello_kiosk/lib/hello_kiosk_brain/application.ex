defmodule HelloKioskBrain.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    HelloKioskBrain.BootTrace.log("application start")

    # p4 is mounted at /root with /data as its stable alias on the Nerves system.
    File.mkdir_p("/data/hello_kiosk")

    # Rotate crash logs and record boot history without blocking startup.
    HelloKioskBrain.CrashLog.rotate()
    HelloKioskBrain.BootLog.record()

    # SSH is started by shoehorn through NervesSSH before this application.
    # Battery/Input/CameraMonitor must start before Kiosk. Kiosk subscribes to Input
    # and hands framebuffer ownership to CameraMonitor when entering camera mode.
    children = [
      HelloKioskBrain.Battery,
      HelloKioskBrain.Input,
      HelloKioskBrain.SwitchBotScanner,
      HelloKioskBrain.BtSpeaker,
      HelloKioskBrain.Audio,
      HelloKioskBrain.BrainClock,
      HelloKioskBrain.TimeSignal,
      HelloKioskBrain.CameraMonitor,
      HelloKioskBrain.KioskLauncher
    ]

    # Potentially dangerous direct PMU charger writes are disabled by default.
    children =
      if Application.get_env(:hello_kiosk_brain, :enable_charger, false) do
        List.insert_at(children, 1, HelloKioskBrain.Charger)
      else
        children
      end

    HelloKioskBrain.BootTrace.log("starting supervisor children")

    opts = [strategy: :one_for_one, name: HelloKioskBrain.Supervisor, max_restarts: 10, max_seconds: 30]
    Supervisor.start_link(children, opts)
  end
end
