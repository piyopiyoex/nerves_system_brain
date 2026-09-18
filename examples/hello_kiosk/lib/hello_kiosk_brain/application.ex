defmodule HelloKioskBrain.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # 起動順: Battery/Input を先に(Kiosk.init が Input.subscribe を呼ぶため)、
    # SshDaemon を Kiosk より前に(Kiosk=NIF 描画が起動に失敗しても SSH を確保)。
    children = [
      HelloKioskBrain.Battery,
      HelloKioskBrain.Input,
      HelloKioskBrain.SshDaemon,
      HelloKioskBrain.Kiosk
    ]

    opts = [strategy: :one_for_one, name: HelloKioskBrain.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
