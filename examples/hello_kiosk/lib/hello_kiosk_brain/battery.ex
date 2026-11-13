defmodule HelloKioskBrain.Battery do
  @moduledoc """
  Battery voltage and 5V (charger/USB) presence for SHARP Brain PW-SH6,
  read from the i.MX28 power block (HW_POWER, base 0x80044000):

    VDD5V (LRADC ch15)  : 5V present when >= 4.0 V (HW_POWER_STS bit 29 is not reliable)
    HW_POWER_BATTMONITOR (0x054): BATT_VAL bit[25:16], 8 mV/LSB -> battery mV

  Uses a small mmap-based `devmem` helper (shipped in priv/bin, copied to an
  exec-capable path at startup) because Erlang's :file can't mmap /dev/mem.
  All reads are best-effort; returns :unknown fields when unavailable.
  """
  use GenServer

  # VDD5V がこれ以上なら 5V あり(実測: 給電中 約 5.1 V、切れると約 0.2 V)
  @vdd5_present_mv 4000
  @sts 0x800440C0
  @battmon 0x80044054
  @poll_ms 5_000

  # 電池ログ: @poll_ms 毎の読取りのうち @log_every 回に 1 回、/data/hello_kiosk/battery.log へ
  # 1 行追記(CSV)。充電/放電の傾向を長時間観察するため。RTC 未設定でも追えるよう
  # uptime(起動からの秒)を記録。os は設定済みなら実時刻、未設定なら 1970 起点。
  @log_path "/data/hello_kiosk/battery.log"
  @log_every 12
  # 追記のみだと際限なく育つので、この行数を超えたら古い方を捨てて後半を残す。
  @log_max_lines 5_000

  # Li-ion single cell approx: 3.3V empty .. 4.2V full
  @mv_empty 3300
  @mv_full 4200

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  CPU(SoC)のダイ温度(℃、小数 1 位)。i.MX28 の LRADC ch8(内蔵温度センサ)を IIO 経由で読む。
  換算は IIO の `(raw + offset) * scale`(offset で K → ℃ になる。実測 約 50 ℃)。読めなければ nil。
  センサのばらつきが ±1.8 ℃ ほどあるので、3 回読んで平均する。
  """
  def cpu_temp_c do
    dir = "/sys/bus/iio/devices/iio:device0"

    with {off, _} <- Float.parse(String.trim(File.read!(dir <> "/in_temp8_offset"))),
         {scale, _} <- Float.parse(String.trim(File.read!(dir <> "/in_temp8_scale"))) do
      raws =
        for _ <- 1..3 do
          {r, _} = Integer.parse(String.trim(File.read!(dir <> "/in_temp8_raw")))
          r
        end

      avg = Enum.sum(raws) / length(raws)
      Float.round((avg + off) * scale, 1)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "電池電圧(mV)から残量(%)。画面表示用。充電中は内部抵抗ぶんの電圧降下を引いた値を渡すこと。"
  def percent_for(mv) when is_integer(mv), do: percent(mv)

  @doc "電池電圧(mV)を今すぐ読む(ポーリングを待たない)。読めなければ nil。Charger の休止電圧測定用。"
  def read_mv_now, do: read_iio_battery_mv()

  @impl true
  def init(_) do
    devmem = ensure_devmem()
    send(self(), :poll)
    {:ok, %{devmem: devmem, mv: nil, raw: nil, sts: nil, on_5v: nil, pct: nil, log_tick: 0}}
  end

  @impl true
  def handle_call(:status, _from, st) do
    {:reply, %{mv: st.mv, percent: st.pct, on_5v: st.on_5v, raw: st.raw}, st}
  end

  @impl true
  def handle_info(:poll, st) do
    st = read(st)
    st = maybe_log(st)
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, st}
  end

  defp read(%{devmem: nil} = st), do: st

  defp read(%{devmem: dm} = st) do
    # Battery voltage: i.MX28 LRADC channel 7 (via IIO) is the real measurement.
    # HW_POWER_BATTMONITOR was a fixed DC-DC setpoint, not measured voltage —
    # that's why it read a constant 55% (verified 2026-09-04: ch7 raw*scale
    # ~= 4.15V while BATTMONITOR stayed 0x270a).
    mv = read_iio_battery_mv()

    # 5V の有無は VDD5V の電圧(LRADC ch15)で判定する。STS の bit 29 は 5V が切れても 1 のままで当てにならない
    # (2026-11-11 実機: 5V が 5.1 V → 0.23 V に落ちても STS=0x20…のまま)。ADC が読めなければ従来の STS に戻す。
    on_5v =
      case read_iio_vdd5_mv() do
        v when is_integer(v) ->
          v >= @vdd5_present_mv

        _ ->
          case reg(dm, @sts) do
            {:ok, sts} -> Bitwise.band(sts, 0x20000000) != 0
            _ -> st.on_5v
          end
      end

    if is_integer(mv) do
      %{st | mv: mv, raw: mv, on_5v: on_5v, pct: percent(mv)}
    else
      %{st | on_5v: on_5v}
    end
  end

  # @log_every 回に 1 回、CSV 1 行を追記。値が未取得(mv=nil)の間はログしない。
  defp maybe_log(%{mv: mv} = st) when is_integer(mv) do
    tick = st.log_tick + 1

    if rem(tick, @log_every) == 0 do
      up = uptime_s()
      line = "#{System.os_time(:second)},#{up},#{mv},#{st.pct},#{st.on_5v}\n"
      append_capped(line)
    end

    %{st | log_tick: tick}
  end

  defp maybe_log(st), do: st

  defp uptime_s do
    case File.read("/proc/uptime") do
      {:ok, s} -> s |> String.split() |> hd() |> String.to_float() |> trunc()
      _ -> 0
    end
  end

  defp append_capped(line) do
    File.mkdir_p(Path.dirname(@log_path))
    unless File.exists?(@log_path) do
      File.write(@log_path, "os_time_s,uptime_s,mv,percent,on_5v\n")
    end

    File.write(@log_path, line, [:append])
    trim_if_big()
  rescue
    _ -> :ok
  end

  # 追記のたびに stat して、行数上限を超えたら後半 @log_max_lines 行だけ残す(ヘッダ再付与)。
  # stat は軽いが毎回 wc は重いので、ファイルサイズ概算(1 行 ~40B)で間引いてから行数確認。
  defp trim_if_big do
    case File.stat(@log_path) do
      {:ok, %{size: sz}} when sz > @log_max_lines * 48 ->
        lines = @log_path |> File.read!() |> String.split("\n", trim: true)

        if length(lines) > @log_max_lines do
          kept = lines |> Enum.drop(1) |> Enum.take(-@log_max_lines)
          File.write(@log_path, "os_time_s,uptime_s,mv,percent,on_5v\n" <> Enum.join(kept, "\n") <> "\n")
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @iio "/sys/bus/iio/devices/iio:device0"
  defp read_iio_vdd5_mv do
    with {:ok, raw_s} <- File.read("#{@iio}/in_voltage15_raw"),
         {:ok, scale_s} <- File.read("#{@iio}/in_voltage15_scale"),
         {raw, _} <- Integer.parse(String.trim(raw_s)),
         {scale, _} <- Float.parse(String.trim(scale_s)) do
      round(raw * scale)
    else
      _ -> nil
    end
  end

  defp read_iio_battery_mv do
    with {:ok, raw_s} <- File.read("#{@iio}/in_voltage7_raw"),
         {:ok, scale_s} <- File.read("#{@iio}/in_voltage7_scale"),
         {raw, _} <- Integer.parse(String.trim(raw_s)),
         {scale, _} <- Float.parse(String.trim(scale_s)) do
      round(raw * scale)
    else
      _ -> nil
    end
  end

  defp percent(mv) do
    p = round((mv - @mv_empty) * 100 / (@mv_full - @mv_empty))
    min(max(p, 0), 100)
  end

  defp reg(devmem, addr) do
    hex = "0x" <> Integer.to_string(addr, 16)

    case System.cmd(devmem, [hex], stderr_to_stdout: true) do
      {out, 0} ->
        s = out |> String.trim() |> String.replace_prefix("0x", "")

        case Integer.parse(s, 16) do
          {v, _} -> {:ok, v}
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  # priv/bin/devmem is on a read-only/exec-ok rootfs already; but be safe and
  # copy to /root (exec-capable) if the priv path isn't executable.
  defp ensure_devmem do
    priv = :code.priv_dir(:hello_kiosk_brain)
    src = Path.join([priv, "bin", "devmem"])
    dst = "/root/devmem"

    cond do
      File.exists?(dst) -> dst
      File.exists?(src) -> copy_exec(src, dst)
      true -> nil
    end
  rescue
    _ -> nil
  end

  defp copy_exec(src, dst) do
    with {:ok, _} <- File.copy(src, dst),
         :ok <- File.chmod(dst, 0o755) do
      dst
    else
      _ -> nil
    end
  end
end
