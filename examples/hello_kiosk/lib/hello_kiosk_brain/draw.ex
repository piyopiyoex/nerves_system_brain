defmodule HelloKioskBrain.Draw do
  @moduledoc """
  KIOSK の描画 API を LovyanGFX command tuple へ変換する純粋な DSL。

  色は整数 `0xRRGGBB`(例 `0xFFA500`)または 6 桁 16 進文字列で指定する。
  """

  @datums %{
    tl: :top_left,
    tc: :top_center,
    tr: :top_right,
    ml: :middle_left,
    mc: :middle_center,
    mr: :middle_right,
    bl: :bottom_left,
    bc: :bottom_center,
    br: :bottom_right
  }

  @fonts %{
    jp8: :japan_gothic_8,
    jp12: :japan_gothic_12,
    jp16: :japan_gothic_16,
    jp20: :japan_gothic_20,
    jp24: :japan_gothic_24,
    jp28: :japan_gothic_28,
    jp32: :japan_gothic_32,
    jp36: :japan_gothic_36,
    jp40: :japan_gothic_40
  }

  @doc "画面全体を color で塗りつぶす"
  def clear(color), do: {:fill_screen, rgb888(color)}

  @doc "塗り矩形"
  def rect(x, y, w, h, color), do: {:fill_rect, x, y, w, h, rgb888(color)}

  @doc "枠線矩形"
  def frame(x, y, w, h, color), do: {:draw_rect, x, y, w, h, rgb888(color)}

  @doc "塗り角丸矩形"
  def rrect(x, y, w, h, r, color), do: {:fill_round_rect, x, y, w, h, r, rgb888(color)}

  @doc "枠線角丸矩形"
  def rframe(x, y, w, h, r, color), do: {:draw_round_rect, x, y, w, h, r, rgb888(color)}

  @doc "直線"
  def line(x1, y1, x2, y2, color), do: {:draw_line, x1, y1, x2, y2, rgb888(color)}

  @doc "枠線円"
  def circle(x, y, r, color), do: {:draw_circle, x, y, r, rgb888(color)}

  @doc "塗り円"
  def fcircle(x, y, r, color), do: {:fill_circle, x, y, r, rgb888(color)}

  @doc """
  テキスト描画。

    * `datum` … 基準点 `:tl :tc :tr :ml :mc :mr :bl :bc :br`
    * `font`  … `:jp8 :jp12 :jp16 :jp20 :jp24 :jp28 :jp32 :jp36 :jp40`
  """
  def text(x, y, datum, font, color, string) do
    [
      {:set_text_datum, datum(datum)},
      {:set_text_color, rgb888(color)},
      {:draw_string, string, x, y, font(font)}
    ]
  end

  # --- helpers ---------------------------------------------------------------

  defp datum(value), do: value |> normalize_name() |> then(&Map.fetch!(@datums, &1))
  defp font(value), do: value |> normalize_name() |> then(&Map.fetch!(@fonts, &1))

  defp normalize_name(value) when is_atom(value), do: value
  defp normalize_name(value) when is_binary(value), do: String.to_existing_atom(value)

  defp rgb888(color) when is_integer(color) and color in 0..0xFFFFFF, do: {:rgb888, color}

  defp rgb888(color) when is_binary(color) do
    case Integer.parse(color, 16) do
      {value, ""} when value in 0..0xFFFFFF -> {:rgb888, value}
      _ -> raise ArgumentError, "expected an RGB888 color, got: #{inspect(color)}"
    end
  end
end
