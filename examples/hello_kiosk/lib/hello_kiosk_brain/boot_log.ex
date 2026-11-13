defmodule HelloKioskBrain.BootLog do
  @moduledoc """
  起動のたびの履歴(`/data/hello_kiosk/boot_history.log`)。ロゴで止まる起動(OS が動く前)は残らないが、**次の起動**に
  「何で起動したか」と「前回が正常終了か」が残るので、止まったときの状況を後から突き合わせられる。

  1 行 = 1 回の起動: `日時 uptime=起動からの秒 powerup=電源投入の要因 prev=前回の終了 boots=通算`
    * `powerup` … `HW_POWER_STS` の上位(bit 29:24 = PWRUP_SOURCE)。起動時に決まり、5V を抜いても変わらない
      (以前、ここを「5V の有無」と誤用していた)。値の意味は実機で突き合わせて分かる(例: 電源ボタン / 5V 挿入 / リセット)。
    * `prev` … 前回の終了。`/root/shutdown_report.txt`(erlinit が正常終了のたびに書く)の更新時刻が前回の起動以降なら
      「正常終了(アクション)」、そうでなければ「異常終了(電源断・リセット)」。
  """
  require Logger

  @log "/data/hello_kiosk/boot_history.log"
  @report "/root/shutdown_report.txt"
  @count "/data/hello_kiosk/boot_count"
  @max_lines 300

  @doc "起動時に 1 回呼ぶ(Application.start)。失敗してもアプリの起動は止めない。"
  def record do
    now = System.os_time(:second)
    up = uptime()
    boot_start = now - up

    last_start = prev_boot_start()

    prev =
      case File.stat(@report, time: :posix) do
        {:ok, %{mtime: m}} -> if m >= last_start, do: "正常終了(" <> action() <> ")", else: "異常終了(前回の起動以降に終了記録なし)"
        _ -> "不明(終了記録なし)"
      end

    sts = devmem(0x800440C0)
    src = if sts, do: Bitwise.band(Bitwise.bsr(sts, 24), 0x3F), else: nil
    n = bump_count()

    line =
      "#{stamp(now)} uptime=#{up} powerup=#{if src, do: "0x" <> Integer.to_string(src, 16), else: "?"} " <>
        "STS=#{if sts, do: "0x" <> Integer.to_string(sts, 16), else: "?"} prev=#{prev} boots=#{n}\n"

    File.write(@log, line, [:append])
    File.write("/data/hello_kiosk/boot_prev_start", Integer.to_string(boot_start))
    trim()
    Logger.info("BootLog: " <> String.trim(line))
    :ok
  rescue
    e ->
      Logger.warning("BootLog failed: #{inspect(e)}")
      :ok
  end

  defp prev_boot_start do
    case File.read("/data/hello_kiosk/boot_prev_start") do
      {:ok, s} -> s |> String.trim() |> Integer.parse() |> then(fn {v, _} -> v end)
      _ -> 0
    end
  end

  defp action do
    case File.read(@report) do
      {:ok, txt} ->
        case Regex.run(~r/Shutdown action: (.+)/, txt) do
          [_, a] -> String.trim(a)
          _ -> "?"
        end

      _ ->
        "?"
    end
  end

  defp bump_count do
    n =
      case File.read(@count) do
        {:ok, s} -> (s |> String.trim() |> Integer.parse() |> then(fn {v, _} -> v end)) + 1
        _ -> 1
      end

    File.write(@count, Integer.to_string(n))
    n
  end

  defp devmem(addr) do
    case System.cmd("/root/devmem", ["0x" <> Integer.to_string(addr, 16)], stderr_to_stdout: true) do
      {o, 0} -> o |> String.trim() |> String.replace_prefix("0x", "") |> Integer.parse(16) |> then(fn {v, _} -> v end)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp uptime do
    case File.read("/proc/uptime") do
      {:ok, s} -> s |> String.split() |> hd() |> String.to_float() |> trunc()
      _ -> 0
    end
  end

  defp stamp(epoch) do
    {{y, mo, d}, {h, mi, s}} = :calendar.system_time_to_universal_time(epoch, :second)
    :io_lib.format("~4..0w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0wZ", [y, mo, d, h, mi, s]) |> IO.iodata_to_binary()
  end

  defp trim do
    with {:ok, txt} <- File.read(@log), lines = String.split(txt, "\n", trim: true), true <- length(lines) > @max_lines do
      File.write(@log, lines |> Enum.take(-div(@max_lines, 2)) |> Enum.join("\n") |> Kernel.<>("\n"))
    end
  end
end
