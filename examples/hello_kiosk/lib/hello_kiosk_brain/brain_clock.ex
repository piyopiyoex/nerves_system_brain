defmodule HelloKioskBrain.BrainClock do
  @moduledoc """
  Brain 内蔵時計(i.MX28 RTC)と Linux 時刻の双方向同期。

  PW-SH6 の時計は i.MX28 SoC 内蔵 RTC(`HW_RTC` @0x80056000)にあり、Brain ファーム(Windows CE 系)は
  秒カウンタを **2000-01-01 00:00:00 起点のローカル(JST)時刻**として保持する(実機で確認)。
  Linux の rtc-stmp3xxx ドライバは 1970 起点 UTC 前提で流儀が合わないため、brain-hackers の DTS では
  RTC ノードが disabled になっており、Linux は起動時 1970 年・NTP 依存になっていた。

  本モジュールはドライバを使わず `/root/devmem` でレジスタを直接読み書きする:
    * 起動時: RTC が妥当(2024〜2100 年)で Linux が未設定(1970 年)なら **RTC → Linux**(`date -s`)。
      オフラインでも正しい時刻で起動でき、NTP が来れば NTP が上書きする。
    * 定期: Linux が NTP 同期済み(2024 年以降)で RTC と 2 秒以上ずれていれば **Linux → RTC**。
      Brain ファームの時計も NTP 精度に揃う(電池切れで RTC が飛んだ後も自動復旧)。
  書込は `HW_RTC_STAT` の NEW_REGS(bits 8-15)が 0 のときだけ行い、PERSISTENT レジスタには触れない。
  """
  use GenServer
  require Logger
  import Bitwise

  @devmem "/root/devmem"
  @reg_stat "0x80056010"
  @reg_seconds "0x80056030"
  @base_2000 946_684_800
  @jst 9 * 3600
  # 妥当とみなす RTC 範囲(UTC epoch): 2024-01-01 .. 2100-01-01
  @min_valid 1_704_067_200
  @max_valid 4_102_444_800
  @check_ms 60_000
  @write_tolerance_s 2
  @min_write_interval_s 600

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "RTC を読んで UTC の DateTime を返す(Brain 流儀から変換)。未設定/異常なら {:error, reason}。"
  def read_rtc do
    with {:ok, raw} <- read_raw() do
      epoch = raw + @base_2000 - @jst

      if epoch >= @min_valid and epoch <= @max_valid,
        do: {:ok, DateTime.from_unix!(epoch)},
        else: {:error, {:rtc_unset, raw}}
    end
  end

  @doc "Linux 時刻を Brain 流儀で RTC に書く。戻り値 {:ok, raw} / {:error, reason}。"
  def write_rtc_from_system do
    now = System.os_time(:second)

    cond do
      now < @min_valid -> {:error, :system_clock_unset}
      ensure_devmem() != :ok -> {:error, :no_devmem}
      true ->
        with {:ok, stat} <- read_hex(@reg_stat),
             true <- (band(stat, 0x0000FF00) == 0) || {:error, :new_regs_pending} do
          raw = now + @jst - @base_2000
          {_, rc} = System.cmd(@devmem, [@reg_seconds, "0x" <> Integer.to_string(raw, 16)], stderr_to_stdout: true)
          if rc == 0, do: {:ok, raw}, else: {:error, {:devmem_rc, rc}}
        end
    end
  end

  @doc """
  手動で時刻を設定する(ネットが無い環境向け。「設定」画面から呼ぶ)。`epoch` は UTC の UNIX 秒。
  Linux の時刻を `date -s` で合わせ、続けて RTC にも書く(電源を切っても Brain ファームの時計と共に保持される)。
  範囲外(2024 年より前、2100 年以降)は拒否する。NTP につながれば後から NTP が上書きする。
  戻り値 `:ok` / `{:error, reason}`(RTC への書き込みだけ失敗したときは `{:error, {:rtc, reason}}`)。
  """
  def set_time(epoch) when is_integer(epoch) do
    if epoch < @min_valid or epoch >= @max_valid do
      {:error, :out_of_range}
    else
      case System.cmd("/bin/date", ["-s", "@#{epoch}"], stderr_to_stdout: true) do
        {_, 0} ->
          case write_rtc_from_system() do
            {:ok, _raw} -> :ok
            {:error, reason} -> {:error, {:rtc, reason}}
          end

        {out, rc} ->
          {:error, {:date_rc, rc, String.trim(out)}}
      end
    end
  end

  @doc "RTC から Linux 時刻を設定(RTC が妥当なときのみ)。"
  def set_system_from_rtc do
    case read_rtc() do
      {:ok, dt} ->
        {_, rc} = System.cmd("/bin/date", ["-s", "@#{DateTime.to_unix(dt)}"], stderr_to_stdout: true)
        if rc == 0, do: {:ok, dt}, else: {:error, {:date_rc, rc}}

      err ->
        err
    end
  end

  # --- GenServer ---

  @impl true
  def init(_) do
    send(self(), :boot_sync)
    Process.send_after(self(), :check, @check_ms)
    {:ok, %{last_write: 0}}
  end

  @impl true
  def handle_info(:boot_sync, state) do
    if System.os_time(:second) < @min_valid do
      case set_system_from_rtc() do
        {:ok, dt} -> Logger.info("BrainClock: system time set from RTC: #{dt}")
        {:error, reason} -> Logger.info("BrainClock: RTC not usable at boot (#{inspect(reason)}); waiting for NTP")
      end
    end

    {:noreply, state}
  end

  def handle_info(:check, state) do
    state = maybe_write(state)
    Process.send_after(self(), :check, @check_ms)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp maybe_write(state) do
    now = System.os_time(:second)

    with true <- now >= @min_valid,
         true <- now - state.last_write >= @min_write_interval_s,
         {:ok, raw} <- read_raw(),
         true <- abs(raw + @base_2000 - @jst - now) > @write_tolerance_s do
      case write_rtc_from_system() do
        {:ok, new_raw} ->
          Logger.info("BrainClock: RTC updated from system (raw #{raw} -> #{new_raw})")
          %{state | last_write: now}

        {:error, reason} ->
          Logger.warning("BrainClock: RTC write failed #{inspect(reason)}")
          state
      end
    else
      _ -> state
    end
  end

  # --- devmem helpers ---

  # /root/devmem は Kiosk.resolve_devmem が priv/bin/devmem から複製する。BrainClock は Kiosk より
  # 先に起動するので、無ければ自分で同じ複製を行う(priv 直下は実行ビットが無いため /root へ)。
  defp ensure_devmem do
    src = Path.join([to_string(:code.priv_dir(:hello_kiosk_brain)), "bin", "devmem"])

    cond do
      File.exists?(@devmem) -> :ok
      File.exists?(src) ->
        with {:ok, _} <- File.copy(src, @devmem), :ok <- File.chmod(@devmem, 0o755), do: :ok, else: (_ -> :error)
      true -> :error
    end
  rescue
    _ -> :error
  end

  defp read_raw, do: read_hex(@reg_seconds)

  defp read_hex(addr) do
    if ensure_devmem() == :ok do
      case System.cmd(@devmem, [addr], stderr_to_stdout: true) do
        {out, 0} ->
          case Integer.parse(out |> String.trim() |> String.replace(~r/^0x/i, ""), 16) do
            {v, _} -> {:ok, v}
            _ -> {:error, {:parse, out}}
          end

        {out, rc} ->
          {:error, {:devmem, rc, String.trim(out)}}
      end
    else
      {:error, :no_devmem}
    end
  end
end
