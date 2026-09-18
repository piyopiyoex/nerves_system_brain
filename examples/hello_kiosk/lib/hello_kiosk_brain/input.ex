defmodule HelloKioskBrain.Input do
  @moduledoc """
  evdev reader for SHARP Brain PW-SH6.

  - touch : /dev/input/event1 (mxs-lradc-ts), ABS_X/ABS_Y in 0..4095, BTN_TOUCH
  - keys  : /dev/input/event0 (brain-kbd-gpio), EV_KEY

  Reads raw struct input_event (16 bytes on 32-bit ARM: 8-byte time + type16 +
  code16 + value32, little-endian) and forwards decoded events to a subscriber
  pid as messages:

    {:touch, x, y}                # mapped to screen pixels (854x480), on release/press
    {:key, code, :down|:up|:repeat}  # :repeat = evdev autorepeat (val=2), 通常は無視
  """
  use GenServer

  @touch_dev ~c"/dev/input/event1"
  @key_dev ~c"/dev/input/event0"
  @scr_w 854
  @scr_h 480

  # Touch calibration (measured on device 2026-09-04): the panel does not span
  # the full 0..4095 ADC range. Empirically x ~195..3897, y ~331..3849.
  @cal_x_min 195
  @cal_x_max 3897
  @cal_y_min 331
  @cal_y_max 3849

  # evdev constants
  @ev_key 0x01
  @ev_abs 0x03
  @abs_x 0x00
  @abs_y 0x01
  @btn_touch 0x14A

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    sub = Keyword.get(opts, :subscriber)
    parent = self()
    # NOTE: a :raw fd can only be read by its controlling (opening) process.
    # So each reader process opens ITS OWN fd — never share/pass a raw fd
    # (doing so crashes with :not_on_controlling_process).
    spawn_link(fn -> open_and_loop(@touch_dev, parent, :touch) end)
    spawn_link(fn -> open_and_loop(@key_dev, parent, :key) end)
    {:ok, %{sub: sub, x: 0, y: 0, down: false}}
  end

  def subscribe(pid), do: GenServer.cast(__MODULE__, {:subscribe, pid})

  @impl true
  def handle_cast({:subscribe, pid}, state), do: {:noreply, %{state | sub: pid}}

  @impl true
  def handle_info({:ev, :touch, type, code, value}, state) do
    state =
      cond do
        type == @ev_abs and code == @abs_x -> %{state | x: value}
        type == @ev_abs and code == @abs_y -> %{state | y: value}
        type == @ev_key and code == @btn_touch -> touch_btn(state, value)
        true -> state
      end

    {:noreply, state}
  end

  def handle_info({:ev, :key, @ev_key, code, value}, state) do
    # evdev key value: 0=離す, 1=押下, 2=オートリピート。
    # オートリピートを :down にすると「1回の押下」で複数発火する(バックライトトグル等が
    # チラつく)。初回押下だけ :down、リピートは :repeat(購読側で無視)に分ける。
    dir =
      case value do
        0 -> :up
        1 -> :down
        _ -> :repeat
      end

    notify(state, {:key, code, dir})
    {:noreply, state}
  end

  def handle_info({:ev, _, _, _, _}, state), do: {:noreply, state}

  defp touch_btn(state, 1), do: %{state | down: true}

  defp touch_btn(state, 0) do
    # release: emit the last coordinate, calibrated to screen pixels
    px = map_axis(state.x, @cal_x_min, @cal_x_max, @scr_w - 1)
    # Y is inverted vs the screen (touching the top switched the bottom tabs).
    py = (@scr_h - 1) - map_axis(state.y, @cal_y_min, @cal_y_max, @scr_h - 1)
    notify(state, {:touch, px, py})
    %{state | down: false}
  end

  # Map a raw ADC value in [lo, hi] to [0, out], clamped.
  defp map_axis(raw, lo, hi, out) do
    v = div((raw - lo) * out, hi - lo)
    v |> max(0) |> min(out)
  end

  defp touch_btn(state, _), do: state

  defp notify(%{sub: pid}, msg) when is_pid(pid), do: send(pid, msg)
  defp notify(_, _), do: :ok

  # --- raw readers (each in its own linked process) ---

  defp open_and_loop(dev, parent, tag) do
    case :file.open(dev, [:read, :raw, :binary]) do
      {:ok, fd} -> read_loop(fd, parent, tag)
      _ -> :ok
    end
  end

  defp read_loop(fd, parent, tag) do
    case :file.read(fd, 16) do
      {:ok, <<_sec::little-32, _usec::little-32, type::little-16, code::little-16, value::little-signed-32>>} ->
        send(parent, {:ev, tag, type, code, value})
        read_loop(fd, parent, tag)

      _ ->
        :ok
    end
  end
end
