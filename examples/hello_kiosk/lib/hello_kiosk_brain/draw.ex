defmodule HelloKioskBrain.Draw do
  @moduledoc """
  描画コマンド列(テキストプロトコル)を組み立てる純粋な DSL。

  各関数は 1 コマンド分の iodata を返す。これらをリストにまとめて
  `HelloKiosk.Display.render/1`(NIF)へ渡すか、ホスト検証では
  そのままファイルへ書き出す。NIF を一切参照しないため、ホスト上の
  Elixir でも単体で実行でき、生成したプロトコルを PNG 化して確認できる。

  色は整数 `0xRRGGBB`(例 `0xFFA500`)または 6 桁 16 進文字列で指定する。
  プロトコルの仕様は `c_src/kiosk_draw.hpp` を参照。
  """

  @doc "画面全体を color で塗りつぶす"
  def clear(color), do: row(["clear", hex(color)])

  @doc "塗り矩形"
  def rect(x, y, w, h, color), do: row(["rect", x, y, w, h, hex(color)])

  @doc "枠線矩形"
  def frame(x, y, w, h, color), do: row(["frame", x, y, w, h, hex(color)])

  @doc "塗り角丸矩形"
  def rrect(x, y, w, h, r, color), do: row(["rrect", x, y, w, h, r, hex(color)])

  @doc "枠線角丸矩形"
  def rframe(x, y, w, h, r, color), do: row(["rframe", x, y, w, h, r, hex(color)])

  @doc "直線"
  def line(x1, y1, x2, y2, color), do: row(["line", x1, y1, x2, y2, hex(color)])

  @doc "枠線円"
  def circle(x, y, r, color), do: row(["circle", x, y, r, hex(color)])

  @doc "塗り円"
  def fcircle(x, y, r, color), do: row(["fcircle", x, y, r, hex(color)])

  @doc """
  テキスト描画。

    * `datum` … 基準点 `:tl :tc :tr :ml :mc :mr :bl :bc :br`
    * `font`  … `:jp8 :jp12 :jp16 :jp20 :jp24 :jp28 :jp32 :jp36 :jp40`
  """
  def text(x, y, datum, font, color, string),
    do: row(["text", x, y, datum, font, hex(color), string])

  # --- helpers ---------------------------------------------------------------

  defp row(fields) do
    [fields |> Enum.map(&field/1) |> Enum.intersperse("\t"), "\n"]
  end

  defp field(v) when is_integer(v), do: Integer.to_string(v)
  defp field(v) when is_atom(v), do: Atom.to_string(v)
  defp field(v) when is_binary(v), do: v

  defp hex(c) when is_integer(c),
    do: c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(6, "0")

  defp hex(c) when is_binary(c), do: c
end
