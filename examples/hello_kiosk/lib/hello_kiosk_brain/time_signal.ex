defmodule HelloKioskBrain.TimeSignal do
  @moduledoc """
  音声時計 — 毎正時(JST HH:00:00)に NHK 風の時報を鳴らす(ON/OFF は保存され、起動時に復元)。

  シーケンス(正時を 0 とした相対時刻。hello_kiosk_raspad3 の TimeSignal と同じ構成):
    * 約 -10s : 音声「只今より N時をお知らせします」(`time/jihouNN.wav`、約 3.2〜3.7 秒)
    * -3,-2,-1s : 予告の短いビープ(`time/beep_short.wav`)
    * 0s : 長いチャイム(`time/chime_long.wav`・約 2 秒) — 立ち上がりが正時に一致

  カウントダウン(ビープ×3+チャイム)は無音ギャップ込みで **1 ストリームに連結**して `Audio.play_seq/1`
  で鳴らす(連続 aplay だと間が空くため)。チャイムの立ち上がりが正時に来るよう、先頭無音と 3 拍ぶん
  (+再生開始の遅れの補正)を前倒しでスケジュールする。
  **連結(約 1 秒)は事前に済ませる**: 再生要求のたびに連結すると、aplay が始まるまで約 1.1 秒かかり、チャイムが
  約 1 秒遅れた(2026-11-10 実機)。連結済みの WAV(`/tmp/hkb_countdown.wav`)を起動後に 1 回作っておき、
  正時の直前は `Audio.play_path/1` で鳴らすだけにする。`@aplay_comp_ms` は aplay の起動〜発音の遅れ(未校正の見積り)。

  1 秒ごとのティッカーで「正時までの残り」を再評価するので、NTP 同期によるクロックの跳びにも追従する。
  時計が未設定(1970 年起点など)のときは鳴らさない。
  """
  use GenServer
  require Logger

  alias HelloKioskBrain.{Audio, Mixer}

  @jst_offset_s 9 * 3600
  @hour_ms 3_600_000
  @tick_ms 1_000
  # 正時の何秒前から予約を入れるか(ティッカーの取りこぼし対策で余裕を持たせる)
  @arm_window_s 12
  # アナウンスは直列キューでカウントダウンの前に鳴る。連結せず(約 1 秒の連結を避け)jihouNN.wav をそのまま鳴らし、
  # 長い最後の 23 時(約 3.7 秒)でもカウントダウンの開始(約 3.4 秒前)までに終わるよう 10 秒前から。
  @announce_before_ms 10_000
  # 再生要求から ALSA の転送開始(trigger_time)まで約 0.45 秒(実測 0.44〜0.46。コーデックの初期化 0.2 秒を含む)。
  # 580 ms にしたら聴感でずれたため 450 ms に戻した。450 ms は許容範囲として確定(しばらく利用して気になれば補正)
  @aplay_comp_ms 450
  @countdown_path "/tmp/hkb_countdown.wav"
  # 再生ストリームの頭切れ防止の先頭無音
  @lead_ms 200
  # ビープ間の無音(beep_short≈120ms なので 1 秒間隔)
  @gap_ms 880
  # 連結内でチャイムが立ち上がるまで(先頭無音 + 3 拍)
  @chime_offset_ms @lead_ms + 3 * (120 + @gap_ms)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  デモ(診断用): 時報の判断に使う時計だけを一時的にずらし、`hour` 時の約 14 秒前から本番と同じ流れ
  (アナウンス → ビープ×3 → チャイム)を `times` 回続けて鳴らす。**実際の時計・RTC には触らない**
  (BrainClock が NTP 後に RTC へ書き戻すため、システム時計は動かさない)。ON/OFF の設定とは無関係に動き、
  終わるとずれを戻す。`HelloKioskBrain.TimeSignal.demo(13, 3)` のように使う。
  """
  def demo(hour, times \\ 3) when hour in 0..23 and times >= 1, do: GenServer.call(__MODULE__, {:demo, hour, times})

  @doc "デモ中の表示用: `{:ok, %{time: \"HH:MM:SS.t\", hour: h, round: n, total: m}}`(ずらした時計)。デモ中でなければ nil。"
  def demo_clock do
    GenServer.call(__MODULE__, :demo_clock, 300)
  catch
    _, _ -> nil
  end

  @doc "デモを途中で終了する(ずれを戻す)。"
  def demo_stop, do: GenServer.call(__MODULE__, :demo_stop)

  @doc "音声時計が ON か。"
  def enabled?, do: GenServer.call(__MODULE__, :enabled?)

  @doc "ON/OFF を設定(保存される)。設定後の値を返す。"
  def set(on?) when is_boolean(on?), do: GenServer.call(__MODULE__, {:set, on?})

  @doc "ON/OFF を反転。設定後の値を返す。"
  def toggle, do: GenServer.call(__MODULE__, :toggle)

  # --- GenServer ------------------------------------------------------------------

  @impl true
  def init(_) do
    tick()
    # 連結済みカウントダウン WAV の作成(CPU を使うので起動の落ち着いた後に)
    Process.send_after(self(), :render, 20_000)
    {:ok, %{enabled: Mixer.get_setting(:clock, 0) == 1, armed: nil, offset_ms: 0, demo: nil}}
  end

  @impl true
  def handle_call(:enabled?, _from, st), do: {:reply, st.enabled, st}
  def handle_call(:toggle, from, st), do: handle_call({:set, not st.enabled}, from, st)

  def handle_call({:demo, hour, times}, _from, st) do
    st = start_demo(st, hour, times, times)
    {:reply, :ok, st}
  end

  def handle_call(:demo_clock, _from, %{demo: nil} = st), do: {:reply, nil, st}

  def handle_call(:demo_clock, _from, %{demo: d} = st) do
    j = jst_now(st)
    t = Calendar.strftime(j, "%H:%M:%S") <> "." <> Integer.to_string(div(elem(j.microsecond, 0), 100_000))
    {:reply, {:ok, %{time: t, hour: d.hour, round: d.total - d.left + 1, total: d.total}}, st}
  end

  def handle_call(:demo_stop, _from, st), do: {:reply, :ok, %{st | demo: nil, offset_ms: 0, armed: nil}}

  def handle_call({:set, on?}, _from, st) do
    Mixer.put_setting(:clock, if(on?, do: 1, else: 0))
    Logger.info("TimeSignal: #{if on?, do: "ON", else: "OFF"}")
    {:reply, on?, %{st | enabled: on?, armed: nil}}
  end

  @impl true
  def handle_info(:tick, st) do
    st = if (st.enabled or st.demo != nil) and clock_ok?(st), do: maybe_arm(st), else: st
    tick()
    {:noreply, st}
  end

  # デモの次の回(または終了)
  def handle_info(:demo_next, %{demo: %{hour: h, left: left, total: total}} = st) when left > 1 do
    {:noreply, start_demo(st, h, left - 1, total)}
  end

  def handle_info(:demo_next, %{demo: %{}} = st) do
    Logger.info("TimeSignal: demo end")
    {:noreply, %{st | demo: nil, offset_ms: 0, armed: nil}}
  end

  def handle_info({:announce, h}, %{enabled: en} = st) when en or st.demo != nil do
    Audio.play_path(Path.join([to_string(:code.priv_dir(:hello_kiosk_brain)), "audio", "time", "jihou#{pad(h)}.wav"]))
    {:noreply, st}
  end

  def handle_info(:render, st) do
    case Audio.render_seq(countdown_items(), @countdown_path) do
      :ok -> Logger.info("TimeSignal: countdown WAV rendered")
      other -> Logger.warning("TimeSignal: render failed #{inspect(other)}")
    end

    {:noreply, st}
  end

  def handle_info(:countdown, %{enabled: en} = st) when en or st.demo != nil do
    Logger.info("TimeSignal: chime")

    # 連結済みの WAV があればそれを鳴らす(遅れが小さい)。無ければ従来どおり都度連結(約 1 秒遅れる)。
    if File.exists?(@countdown_path), do: Audio.play_path(@countdown_path), else: Audio.play_seq(countdown_items())
    {:noreply, st}
  end

  def handle_info(_msg, st), do: {:noreply, st}

  defp countdown_items do
    [
      {:silence, @lead_ms},
      "time/beep_short",
      {:silence, @gap_ms},
      "time/beep_short",
      {:silence, @gap_ms},
      "time/beep_short",
      {:silence, @gap_ms},
      "time/chime_long"
    ]
  end

  # --- 予約 ------------------------------------------------------------------------

  defp maybe_arm(st) do
    ms = ms_to_boundary(st)
    secs = ms / 1000
    target = boundary_hour(st)

    cond do
      secs <= @arm_window_s and st.armed != target ->
        Logger.info("TimeSignal: arm for #{target}:00 (#{Float.round(secs, 1)}s)")
        sched({:announce, target}, ms - @announce_before_ms)
        sched(:countdown, ms - @chime_offset_ms - @aplay_comp_ms)
        %{st | armed: target}

      secs > @arm_window_s + 8 ->
        %{st | armed: nil}

      true ->
        st
    end
  end

  defp tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp sched(msg, delay) when delay > 0, do: Process.send_after(self(), msg, delay)
  defp sched(_msg, _delay), do: :skip

  # デモ開始: 判断用の時計を「hour 時の 14 秒前」にずらす。実時間で約 20 秒後(チャイム後)に次の回へ。
  defp start_demo(st, hour, left, total) do
    now = DateTime.add(DateTime.utc_now(), @jst_offset_s, :second)
    target = %{now | hour: rem(hour + 23, 24), minute: 59, second: 46, microsecond: {0, 0}}
    offset = DateTime.diff(target, now, :millisecond)
    Logger.info("TimeSignal: demo #{hour}時 残り#{left}回(offset #{offset} ms)")
    Process.send_after(self(), :demo_next, 20_000)
    %{st | offset_ms: offset, armed: nil, demo: %{hour: hour, left: left, total: total}}
  end

  defp ms_to_boundary(st) do
    j = jst_now(st)
    {us, _} = j.microsecond
    @hour_ms - (j.minute * 60 + j.second) * 1000 - div(us, 1000)
  end

  defp boundary_hour(st), do: rem(jst_now(st).hour + 1, 24)
  defp clock_ok?(st), do: jst_now(st).year >= 2024
  defp jst_now(st), do: DateTime.add(DateTime.utc_now(), @jst_offset_s * 1000 + st.offset_ms, :millisecond)
  defp pad(n), do: String.pad_leading("#{n}", 2, "0")
end
