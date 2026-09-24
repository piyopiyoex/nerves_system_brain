defmodule HelloKioskBrain.BootTrace do
  @moduledoc false

  @path "/root/hello_kiosk_boot.log"

  def log(message) do
    if enabled?() do
      line = "#{uptime_s()} #{message}"

      IO.puts("hello_kiosk: #{message}")
      File.write(@path, line <> "\n", [:append])
    end

    :ok
  rescue
    _ -> :ok
  end

  defp enabled? do
    Application.get_env(:hello_kiosk_brain, :boot_trace, false)
  end

  defp uptime_s do
    case File.read("/proc/uptime") do
      {:ok, uptime} ->
        uptime
        |> String.split()
        |> List.first()
        |> case do
          nil -> "0.00"
          seconds -> seconds
        end

      _ ->
        "0.00"
    end
  end
end
