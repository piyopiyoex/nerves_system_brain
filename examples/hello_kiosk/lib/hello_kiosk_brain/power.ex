defmodule HelloKioskBrain.Power do
  @moduledoc """
  電源 OFF / 再起動を素早く行う。

  `/sbin/poweroff` と `/sbin/reboot`(busybox)は PID 1(erlinit)にシグナルを送るだけで、erlinit は
  **Erlang VM が自分で終了するのを最大 `--graceful-shutdown-timeout`(既定 10 秒)待つ**。VM を止める指示は erlinit には無いので、
  シグナルを送った後に **`:init.stop/0` で VM を正常終了**させる(さもないと毎回タイムアウトまで待つ)。

  順序が重要: **先にシグナル**(erlinit が「意図的な終了」と認識)、**後で `:init.stop`**。逆だと erlinit は VM の突然の終了と
  みなして `--run-on-exit /bin/sh` を実行し、電源が切れない。SIGUSR2/SIGTERM(12/15)は SIGCHLD(17)より先に配送される。
  """

  @doc "電源を切る(poweroff シグナル → VM を正常終了)。"
  def poweroff, do: shutdown("/sbin/poweroff")

  @doc "再起動する。"
  def reboot, do: shutdown("/sbin/reboot")

  defp stop_charging do
    HelloKioskBrain.Charger.force(false)
  catch
    _, _ -> :ok
  end

  # 電源断・再起動の直前の電源回路の状態を /data/hello_kiosk/poweroff_attempt.log に残す(電池駆動で「切れない」ときの調査用。
  # 電源が切れた/切れなかった/再起動した、のどれでも、次の起動後にこのログと /root/shutdown_report.txt で分かる)。
  defp log_attempt(cmd) do
    rd = fn a ->
      case System.cmd("/root/devmem", ["0x" <> Integer.to_string(a, 16)], stderr_to_stdout: true) do
        {o, 0} -> String.trim(o)
        _ -> "?"
      end
    end

    v5 =
      case File.read("/sys/bus/iio/devices/iio:device0/in_voltage15_raw") do
        {:ok, s} -> s |> String.trim() |> Integer.parse() |> then(fn {r, _} -> round(r * 1.806640625) end)
        _ -> -1
      end

    up = File.read!("/proc/uptime") |> String.split() |> hd()

    line =
      "uptime=#{up} #{Path.basename(cmd)} vdd5=#{v5}mV STS=#{rd.(0x800440C0)} CHARGE=#{rd.(0x80044030)} " <>
        "5VCTRL=#{rd.(0x80044010)} DCDC4P2=#{rd.(0x80044080)} RESET=#{rd.(0x80044100)} CTRL=#{rd.(0x80044000)}\n"

    File.write("/data/hello_kiosk/poweroff_attempt.log", line, [:append])
  rescue
    _ -> :ok
  end

  defp shutdown(cmd) do
    # 電源断の前に充電を止める(充電が有効なまま電源断を指示すると、電池駆動でも切れない可能性がある。
    # 2026-11-11 に電池駆動で一度切れなかった。そのときは充電中だった可能性があるが未確認)。Charger が無くても続行する。
    stop_charging()
    log_attempt(cmd)
    System.cmd(cmd, [])
    # erlinit がシグナルを処理して待機状態に入るのを待ってから VM を止める
    Process.sleep(300)
    :init.stop()
    :ok
  end
end
