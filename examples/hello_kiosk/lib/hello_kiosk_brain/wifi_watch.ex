defmodule HelloKioskBrain.WifiWatch do
  @moduledoc """
  Passive Wi-Fi status adapter for Kiosk. VintageNet manages WLAN recovery.

  The original standalone `WifiWatch` forcibly killed network daemons and
  reset USB ports. Those operations conflict with NervesPack/VintageNet and
  are deliberately not included here.
  """

  @ifname "wlan0"

  @doc "Return the Kiosk-compatible status tuple {status, retry_count}."
  def display do
    cond do
      not File.exists?("/sys/class/net/#{@ifname}") -> {:no_dongle, 0}
      HelloKioskBrain.WifiConfig.connected_ssid() == nil -> {:no_link, 0}
      true -> {:no_ip, 0}
    end
  end

  @doc "Hand a manual interface restart to VintageNet without resetting USB hardware."
  def restart_now do
    VintageNet.configure(@ifname, VintageNet.get_configuration(@ifname), persist: false)
  rescue
    _ -> {:error, :vintage_net_unavailable}
  catch
    :exit, _ -> {:error, :vintage_net_unavailable}
  end

  @doc "For diagnostics: VintageNet is responsible for recovery attempts."
  def status, do: %{manager: :vintage_net, display: display()}
end
