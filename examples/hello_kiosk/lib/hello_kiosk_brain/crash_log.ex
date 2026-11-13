defmodule HelloKioskBrain.CrashLog do
  @moduledoc """
  前回の VM 異常終了(erl_crash.dump)を、次の起動時に時刻付きで退避する。

  `erlinit.config` の `ERL_CRASH_DUMP=/root/erl_crash.dump` は毎回上書きされるので、そのままだと
  「時々起きるフリーズ」の原因が次のクラッシュで消えてしまう。起動時に `/data/hello_kiosk/crash/` へ移し、
  新しい 3 世代だけ残す。先頭の Slogan(終了理由)は `/data/hello_kiosk/crash/index.log` に 1 行ずつ追記する。
  """
  require Logger

  @dump "/root/erl_crash.dump"
  @dir "/data/hello_kiosk/crash"
  @keep 3

  @doc "起動時に 1 回呼ぶ。失敗してもアプリの起動は止めない。"
  def rotate do
    with {:ok, info} <- File.stat(@dump, time: :local) do
      File.mkdir_p!(@dir)
      stamp = stamp(info.mtime)
      dest = Path.join(@dir, "erl_crash.#{stamp}.dump")
      File.rename!(@dump, dest)
      File.write(Path.join(@dir, "index.log"), "#{stamp} #{slogan(dest)}\n", [:append])
      prune()
      Logger.warning("CrashLog: previous crash dump saved to #{dest}")
    end

    :ok
  rescue
    e ->
      Logger.warning("CrashLog.rotate failed: #{inspect(e)}")
      :ok
  end

  defp stamp({{y, mo, d}, {h, mi, s}}) do
    :io_lib.format("~4..0w~2..0w~2..0w-~2..0w~2..0w~2..0w", [y, mo, d, h, mi, s]) |> IO.iodata_to_binary()
  end

  # dump 3 行目の "Slogan: ..." だけ読む(数 MB のファイルを全部読まない)。
  defp slogan(path) do
    with {:ok, f} <- File.open(path, [:read, :binary]) do
      text = IO.binread(f, 600)
      File.close(f)

      case is_binary(text) && Regex.run(~r/^Slogan: (.*)$/m, text) do
        [_, s] -> s
        _ -> "(no slogan)"
      end
    else
      _ -> "(unreadable)"
    end
  end

  defp prune do
    @dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".dump"))
    |> Enum.sort(:desc)
    |> Enum.drop(@keep)
    |> Enum.each(&File.rm(Path.join(@dir, &1)))
  end
end
