defmodule HelloKioskBrain.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    HelloKioskBrain.BootTrace.log("application start")

    # SSH is started by shoehorn through NervesSSH before this application.
    # Battery/Input/CameraMonitor must start before Kiosk. Kiosk subscribes to Input
    # and hands framebuffer ownership to CameraMonitor when entering camera mode.
    children = [
      HelloKioskBrain.Battery,
      HelloKioskBrain.Input,
      HelloKioskBrain.CameraMonitor,
      HelloKioskBrain.KioskLauncher
    ]

    HelloKioskBrain.BootTrace.log("starting supervisor children")

    opts = [strategy: :one_for_one, name: HelloKioskBrain.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
