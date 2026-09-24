defmodule HelloKioskBrain.UsbMode do
  @moduledoc """
  PW-SH6 の USB0 モード(HOST / NCM)を扱う薄い application adapter。

  現在のモードは Device Tree の `dr_mode` から読み取る。次回起動時のモード切り替えは
  System が提供する `/usr/bin/brain-usb-mode` に委譲し、application 自身は DTB を保持・
  mount・書き換えしない。
  """

  @command "/usr/bin/brain-usb-mode"
  @dr_mode "/proc/device-tree/ahb@80080000/usb@80080000/dr_mode"

  @type mode :: :host | :ncm | :unknown

  @doc "現在動作中の USB0 モードを Device Tree から返す。"
  @spec current() :: mode
  def current do
    case File.read(@dr_mode) do
      {:ok, value} ->
        case String.trim(value, <<0>>) do
          "host" -> :host
          "peripheral" -> :ncm
          _ -> :unknown
        end

      _ ->
        :unknown
    end
  end

  @doc "System の USB モード切り替え helper が利用できるか。"
  @spec supported?() :: boolean()
  def supported?, do: File.exists?(@command)

  @doc "次回起動時の USB0 モードを設定する。再起動は行わない。"
  @spec switch(:host | :ncm) :: :ok | {:error, term()}
  def switch(mode) when mode in [:host, :ncm] do
    case System.cmd(@command, [Atom.to_string(mode)], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:usb_mode, status, String.trim(output)}}
    end
  rescue
    error -> {:error, error}
  end

  @doc "次回起動時の USB0 モードを設定し、1.5 秒後に再起動する。"
  @spec switch_and_reboot(:host | :ncm) :: :ok | {:error, term()}
  def switch_and_reboot(mode) when mode in [:host, :ncm] do
    case switch(mode) do
      :ok ->
        spawn(fn ->
          Process.sleep(1_500)
          System.cmd("/sbin/reboot", [])
        end)

        :ok

      error ->
        error
    end
  end
end
