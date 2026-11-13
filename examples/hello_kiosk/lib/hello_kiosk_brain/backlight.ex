defmodule HelloKioskBrain.Backlight do
  @moduledoc """
  LCD バックライトの明るさ(5 段階 + 消灯)。

  PW-SH6 のバックライト調光入力は **PWM0 パッド(GPIO3_16)** につながっており、DTB(`priv/dtb`)で
  PWM0(1 kHz)をそのパッドに出して `pwm-backlight`(`/sys/class/backlight/backlight@0`)で制御する。
  sysfs の `brightness` は 0 = 消灯、1..5 = 5 段階(デューティ 6/16/35/63/100 %)。
  旧 DTB(最大 7、パッドが違う)では画面に効かないが、書き込み自体は無害。

  段階(1..5)は `/data/hello_kiosk/kiosk_settings.term` に保存し、起動時に `apply_saved/0` で反映する。
  """
  alias HelloKioskBrain.Mixer

  @dir "/sys/class/backlight/backlight@0"
  @levels 5

  @doc "段階の最大値(5)"
  def max, do: @levels

  @doc "保存されている明るさの段階(1..5)。既定は最大。"
  def level, do: Mixer.get_setting(:bl, @levels) |> clamp()

  @doc "段階(1..5)を設定して即反映・保存し、設定後の段階を返す。"
  def set_level(n) when is_integer(n) do
    n = clamp(n)
    Mixer.put_setting(:bl, n)
    apply_async()
    n
  end

  # sysfs への書き込み(pwm-backlight の PWM 設定)は 1 回 60〜90 ms かかり、明るさの +/- を押すたびに同期で行うと
  # 画面の反応が重くなる。別プロセスで適用し、連打は最後の値だけ反映する(適用中に来た要求は、終わってから最新の保存値で
  # 再適用。Mixer の音量の適用と同じ仕組み)。
  defp apply_async do
    case Process.whereis(:backlight_apply) do
      pid when is_pid(pid) -> send(pid, :again)
      nil -> spawn(&run_worker/0)
    end

    :ok
  end

  defp run_worker do
    Process.register(self(), :backlight_apply)
    apply_loop()
    Process.unregister(:backlight_apply)

    receive do
      :again -> run_worker()
    after
      0 -> :ok
    end
  rescue
    ArgumentError -> if pid = Process.whereis(:backlight_apply), do: send(pid, :again)
  end

  defp apply_loop do
    apply_saved()

    receive do
      :again ->
        drain()
        apply_loop()
    after
      0 -> :ok
    end
  end

  defp drain do
    receive do
      :again -> drain()
    after
      0 -> :ok
    end
  end

  @doc "保存済みの段階を反映する(起動時・点灯時)。"
  def apply_saved, do: write_raw(raw_for(level()))

  @doc "点灯(保存済みの段階)"
  def on, do: apply_saved()

  @doc "消灯(sysfs 0)。設定の段階は変えない。"
  def off, do: write_raw(0)

  @doc "sysfs の現在値(0..max_brightness)。無ければ :error"
  def get, do: read_int("brightness")

  # 段階 → sysfs 値。新 DTB は max_brightness=5 なので段階そのまま。旧 DTB(7)は比例換算。
  defp raw_for(n) do
    case read_int("max_brightness") do
      m when is_integer(m) and m > 0 -> if m == @levels, do: n, else: round(n * m / @levels)
      _ -> n
    end
  end

  defp write_raw(v) do
    case File.write(Path.join(@dir, "brightness"), Integer.to_string(v)) do
      :ok -> :ok
      _ -> :error
    end
  end

  defp read_int(name) do
    with {:ok, s} <- File.read(Path.join(@dir, name)),
         {v, _} <- Integer.parse(String.trim(s)) do
      v
    else
      _ -> :error
    end
  end

  defp clamp(n) when is_integer(n), do: n |> Kernel.max(1) |> min(@levels)
  defp clamp(_), do: @levels
end
