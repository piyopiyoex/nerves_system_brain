defmodule HelloKioskBrain.Charger do
  @moduledoc """
  電池の充電制御(PW-SH6 / i.MX28 の電源ブロック HW_POWER)。

  Linux には PMU の充電ドライバが無く、ブート ROM は電池が深く放電したときだけ 80 mA で充電を有効にする。
  Brain 本来の CE はソフトウェアで充電を有効化・停止しており、その手順(`docs/20261110_CEサービスメニュー_調査_充電制御の読み取り.md`)
  に沿って、保守的な値だけで同じことを行う。

  方針(1,800 mAh のリチウムイオン 1 セル、ヒステリシス付き):
    * 5V(USB)があり、電池が `@start_mv`(4.10 V)以下 → 充電開始(80 mA、満充電判定電流 50 mA = CE の最も保守的な値)
    * 電池が `@stop_mv`(4.15 V)以上、または 5V が無くなった → 充電停止(PWD_BATTCHRG を立てる)。
      充電中は内部抵抗で電圧が高く測れる(80 mA で約 +50 mV、実測)ので、30 秒ごとに充電を約 1.5 秒止めて
      **休止電圧**で判定し、未達なら再開する
    * 休止電圧が `@max_mv`(4.20 V)以上なら無条件で停止
  CE の「満充電で止める」動作と同じで、トリクル充電(浮動充電)はしない(電池の寿命のため)。

  **未実装・未確認**: 電池温度(0〜40 ℃ が使用範囲)による制限は読んでいない。電流が実際に流れているかを
  測る手段が無い(電圧の変化と状態ビットで推定)。高速充電(360〜440 mA)は使わない(5V の供給能力が不明)。

  ON/OFF は設定 `:chg`(本移植では既定 0、かつ supervisor にも opt-in が必要)。動作は `/data/hello_kiosk/charger.log` に記録する。
  """
  use GenServer
  require Logger

  alias HelloKioskBrain.{Battery, Mixer}

  @charge 0x80044030
  @set 0x80044034
  @clr 0x80044038
  # CHARGE: [5:0] BATTCHRG_I(10 mA/LSB)、[11:8] STOP_ILIMIT、bit16 PWD_BATTCHRG(1=充電停止)
  @pwd 0x10000
  @iset_mask 0x3F
  @stop_mask 0xF00
  # STOP_ILIMIT 0x4 = 50 mA(ブート ROM の 0x408 と同じ)
  @stop_val 0x400
  # 既定の電流コード 8 = 80 mA(CE の最も保守的な値)。`set_current_ma/1` で変更できる(設定 `:chg_code` に保存)。
  @default_code 8
  # 設定できる範囲: 40〜440 mA(CE が使う最大 440 mA まで)。CE は 240 mA(コード 24)を特別扱いして 80 mA に丸める
  # (5VCTRL の切替条件)ので、240 mA は 250 mA に寄せる。
  @min_code 4
  @max_code 44

  @start_mv 4100
  @stop_mv 4150
  @max_mv 4200
  @poll_ms 30_000
  # 休止電圧の測定: 充電を止めてから読むまでの待ち(内部抵抗の電圧降下は直ちに戻る)
  @rest_ms 1_500
  # 充電中の測定値で無条件に止める余裕(80 mA の内部抵抗ぶん)
  @ir_margin_mv 100

  @log "/data/hello_kiosk/charger.log"
  @log_max 300

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "充電中か(CHARGE レジスタで充電が有効かつ電流が設定されている)。サーバ未起動は false。"
  def charging? do
    GenServer.call(__MODULE__, :charging?)
  catch
    _, _ -> false
  end

  @doc """
  満充電か(画面の「満充電」表示用)。5V があり、充電しておらず、電池が開始しきい値(4.10 V)を上回っている状態。
  満充電で止まったあと、電圧が 4.10 V 以下に下がって充電を再開するまで true。状態を持たない定義なので、再起動後も同じ。
  """
  def full? do
    GenServer.call(__MODULE__, :full?)
  catch
    :exit, _ -> false
  end

  # 電池の内部抵抗(実測 約 0.65 Ω。2 台で 0.63〜0.65)。充電中の電池電圧はこの抵抗 × 充電電流ぶん高く測れる。
  @internal_ohm 0.65

  @doc """
  充電中の電圧降下(mV)の推定。充電中でなければ 0。画面の残量(%)は、測定電圧からこれを引いた休止電圧相当で出す
  (引かないと、80 mA で約 +50 mV = 残量が約 5% 多く見える)。
  """
  def ir_drop_mv do
    GenServer.call(__MODULE__, :ir_drop_mv)
  catch
    _, _ -> 0
  end

  @doc "状態の要約(画面・診断用)。"
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  診断用: 電池電圧の開始条件を無視して充電を有効 / 停止にする(`true` / `false`)。
  有効にしても、次の判断(30 秒ごと)で停止条件(4.15 V 以上・5V なし・上限)に当たれば止まる。
  """
  def force(on?) when is_boolean(on?), do: GenServer.call(__MODULE__, {:force, on?})

  @doc """
  充電電流を mA で設定する(10 mA 刻み、40〜440 mA。保存される)。充電中ならすぐ反映する。
  設定後の電流(mA)を返す。**5V の供給能力(アダプタ 1.0 A、本体消費は最大約 4 W)を確かめてから上げる**こと。
  """
  def set_current_ma(ma) when is_integer(ma), do: GenServer.call(__MODULE__, {:set_current, ma})

  @doc "充電制御の ON/OFF(保存される)。OFF にすると充電中なら止める。"
  def set_enabled(on?) when is_boolean(on?), do: GenServer.call(__MODULE__, {:set_enabled, on?})

  # --- GenServer ------------------------------------------------------------------

  @impl true
  def init(_) do
    dm = if File.exists?("/root/devmem"), do: "/root/devmem"
    Process.send_after(self(), :poll, 10_000)
    st = %{dm: dm, enabled: Mixer.get_setting(:chg, 0) == 1, charging: nil, why: "起動", code: clamp_code(Mixer.get_setting(:chg_code, @default_code))}
    {:ok, %{st | charging: read_charging(st)}}
  end

  @impl true
  def handle_call(:charging?, _from, st), do: {:reply, st.charging == true, st}

  def handle_call(:ir_drop_mv, _from, st), do: {:reply, if(st.charging == true, do: round(st.code * 10 * @internal_ohm), else: 0), st}

  def handle_call(:full?, _from, st) do
    full =
      case Battery.status() do
        %{mv: mv, on_5v: true} when is_integer(mv) -> read_charging(st) == false and mv > @start_mv
        _ -> false
      end

    {:reply, full, st}
  catch
    _, _ -> {:reply, false, st}
  end

  def handle_call(:status, _from, st) do
    {:reply, %{enabled: st.enabled, charging: st.charging, ma: st.code * 10, start_mv: @start_mv, stop_mv: @stop_mv, why: st.why}, st}
  end

  def handle_call({:force, true}, _from, st) do
    st = enable(st, nil)
    {:reply, st.charging, st}
  end

  def handle_call({:force, false}, _from, st) do
    st = disable(st, "手動停止")
    {:reply, st.charging, st}
  end

  def handle_call({:set_current, ma}, _from, st) do
    code = clamp_code(div(ma, 10))
    Mixer.put_setting(:chg_code, code)
    st = %{st | code: code}
    st = if st.charging == true, do: resume(st, nil), else: st
    Logger.info("Charger: 電流 #{code * 10} mA")
    {:reply, code * 10, st}
  end

  def handle_call({:set_enabled, on?}, _from, st) do
    Mixer.put_setting(:chg, if(on?, do: 1, else: 0))
    st = %{st | enabled: on?}
    st = if not on? and st.charging == true, do: disable(st, "制御を OFF"), else: st
    {:reply, on?, st}
  end

  @impl true
  def handle_info(:poll, st) do
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, decide(st)}
  end

  def handle_info(_, st), do: {:noreply, st}

  # --- 判断 -------------------------------------------------------------------------

  defp decide(%{dm: nil} = st), do: st

  defp decide(st) do
    case Battery.status() do
      %{mv: mv, on_5v: on_5v} when is_integer(mv) and is_boolean(on_5v) ->
        st = %{st | charging: read_charging(st)}
        act(st, mv, on_5v)

      _ ->
        st
    end
  catch
    _, _ -> st
  end

  # 充電中の電池電圧は内部抵抗ぶん高く測れる(80 mA で約 +50 mV、実測)。そのため、判定のたびに
  # 充電を @rest_ms だけ止め、休止電圧で満充電を判定する(未達なら再開)。
  defp act(%{charging: true} = st, mv, on_5v) do
    cond do
      not st.enabled ->
        disable(st, "制御が OFF")

      not on_5v ->
        disable(st, "5V なし", mv)

      mv >= @max_mv + @ir_margin_mv ->
        disable(st, "電圧上限(測定 #{mv} mV)", mv)

      true ->
        st = pause(st)
        rest = Battery.read_mv_now()

        cond do
          not is_integer(rest) -> resume(st, mv)
          rest >= @max_mv -> disable(st, "電圧上限(休止 #{@max_mv} mV 以上)", rest)
          rest >= @stop_mv -> disable(st, "満充電(休止 #{@stop_mv} mV 以上)", rest)
          true -> resume(st, rest)
        end
    end
  end

  defp act(%{charging: false} = st, mv, on_5v) do
    if st.enabled and on_5v and mv <= @start_mv, do: enable(st, mv), else: st
  end

  defp act(st, _mv, _on_5v), do: st

  # --- レジスタ操作(CE と同じ手順)-------------------------------------------------

  # 休止電圧の測定のために一時停止 / 条件を満たさなければ再開(ログは残さない)
  defp pause(st) do
    w(st, @set, @pwd)
    Process.sleep(@rest_ms)
    st
  end

  defp resume(st, _mv) do
    w(st, @clr, @stop_mask)
    w(st, @set, @stop_val)
    w(st, @clr, @iset_mask)
    w(st, @set, st.code)
    w(st, @clr, @pwd)
    %{st | charging: read_charging(st)}
  end

  defp clamp_code(c) when is_integer(c) do
    c = c |> max(@min_code) |> min(@max_code)
    if c == 24, do: 25, else: c
  end

  defp clamp_code(_), do: @default_code

  defp enable(st, mv) do
    # STOP_ILIMIT を 50 mA に、BATTCHRG_I を設定してから PWD_BATTCHRG を解除
    w(st, @clr, @stop_mask)
    w(st, @set, @stop_val)
    w(st, @clr, @iset_mask)
    w(st, @set, st.code)
    w(st, @clr, @pwd)
    finish(st, true, "充電開始(#{st.code * 10} mA)", mv)
  end

  defp disable(st, why, mv \\ nil) do
    w(st, @clr, @stop_mask)
    w(st, @clr, @iset_mask)
    w(st, @set, @pwd)
    finish(st, false, "充電停止: " <> why, mv)
  end

  defp finish(st, want, why, mv) do
    got = read_charging(st)
    reg = read(st, @charge)
    log("#{why} mv=#{mv} CHARGE=#{fmt(reg)} => #{inspect(got)}")
    if got != want, do: Logger.warning("Charger: 期待 #{want} 実際 #{inspect(got)}")
    %{st | charging: got, why: why}
  end

  # 充電が有効 = PWD_BATTCHRG が 0 で BATTCHRG_I が 0 でない
  defp read_charging(st) do
    case read(st, @charge) do
      {:ok, v} -> Bitwise.band(v, @pwd) == 0 and Bitwise.band(v, @iset_mask) != 0
      _ -> nil
    end
  end

  defp read(%{dm: nil}, _), do: :error

  defp read(%{dm: dm}, addr) do
    case System.cmd(dm, ["0x" <> Integer.to_string(addr, 16)], stderr_to_stdout: true) do
      {out, 0} ->
        case out |> String.trim() |> String.replace_prefix("0x", "") |> Integer.parse(16) do
          {v, _} -> {:ok, v}
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp w(%{dm: dm}, addr, val) do
    System.cmd(dm, ["0x" <> Integer.to_string(addr, 16), "0x" <> Integer.to_string(val, 16)], stderr_to_stdout: true)
  end

  defp fmt({:ok, v}), do: "0x" <> String.pad_leading(Integer.to_string(v, 16), 8, "0")
  defp fmt(_), do: "?"

  defp log(msg) do
    up = File.read!("/proc/uptime") |> String.split() |> hd()
    line = "uptime=#{up} #{msg}\n"
    File.write(@log, line, [:append])

    with {:ok, txt} <- File.read(@log), lines = String.split(txt, "\n", trim: true), true <- length(lines) > @log_max do
      File.write(@log, lines |> Enum.take(-div(@log_max, 2)) |> Enum.join("\n") |> Kernel.<>("\n"))
    end

    Logger.info("Charger: " <> msg)
  rescue
    _ -> :ok
  end
end
