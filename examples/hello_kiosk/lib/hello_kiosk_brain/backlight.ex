defmodule HelloKioskBrain.Backlight do
  @moduledoc """
  LCD バックライト制御(pwm-backlight)。

  `/sys/class/backlight/backlight@0/brightness`(0..7)を書くだけの薄いラッパ。
  無操作スリープ(画面消灯)で使う。sysfs が無い環境では何もしない(:error 返し)。
  """
  @path "/sys/class/backlight/backlight@0/brightness"
  @max 7

  @doc "最大輝度(7)"
  def max, do: @max

  @doc "点灯(最大輝度)"
  def on, do: set(@max)

  @doc "現在の輝度を読む。0..7 | :error"
  def get do
    with {:ok, s} <- File.read(@path),
         {v, _} <- Integer.parse(String.trim(s)) do
      v
    else
      _ -> :error
    end
  end

  @doc "消灯(輝度0)。LCD の主消費を落とす"
  def off, do: set(0)

  @doc "輝度を 0..7 で設定。:ok | :error"
  def set(v) when is_integer(v) and v >= 0 do
    case File.write(@path, Integer.to_string(min(v, @max))) do
      :ok -> :ok
      _ -> :error
    end
  end
end
