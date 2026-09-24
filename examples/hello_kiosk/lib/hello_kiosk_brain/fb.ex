defmodule HelloKioskBrain.Fb do
  @moduledoc """
  Shadow-framebuffer drawing for SHARP Brain PW-SH6 (854x480, 16bpp RGB565 LE).

  WHY shadow: braindrmfb is very slow at many small pwrites — measured ~0.68s
  for one 4-char draw_text when each pixel-cell was its own pwrite (2026-09-04).
  So ALL drawing happens in an in-memory frame (map of row binaries); the
  device is written only by flush/1, as ONE contiguous pwrite.

  Device facts honored here:
    * a :raw fd must be written with :file.pwrite, not IO.binwrite
    * pass a single concatenated binary to pwrite, not a nested iolist

  Drawing functions are functional: take and return a %Fb{}. draw_text returns
  {fb, pixel_width}. flush once per batch.
  """

  defstruct [:rows]

  @width 854
  @height 480
  @bpp 2
  @stride @width * @bpp

  def width, do: @width
  def height, do: @height

  def new do
    blank = :binary.copy(<<0, 0>>, @width)
    rows = Map.new(0..(@height - 1), fn y -> {y, blank} end)
    %__MODULE__{rows: rows}
  end

  def color(r, g, b) do
    v =
      Bitwise.bor(
        Bitwise.bor(
          Bitwise.bsl(Bitwise.bsr(r, 3), 11),
          Bitwise.bsl(Bitwise.bsr(g, 2), 5)
        ),
        Bitwise.bsr(b, 3)
      )

    <<v::little-16>>
  end

  def fill_screen(%__MODULE__{} = fb, color), do: fill_rect(fb, 0, 0, @width, @height, color)

  def fill_rect(%__MODULE__{rows: rows} = fb, x, y, w, h, color) do
    x = max(x, 0)
    y = max(y, 0)
    w = min(w, @width - x)
    h = min(h, @height - y)

    if w > 0 and h > 0 do
      line = :binary.copy(color, w)
      new_rows = Enum.reduce(y..(y + h - 1), rows, fn j, acc -> stamp(acc, x, j, line) end)
      %{fb | rows: new_rows}
    else
      fb
    end
  end

  def draw_text(%__MODULE__{} = fb, x, y, text, fg, bg, scale \\ 2) do
    chars = text |> String.upcase() |> String.to_charlist()

    fb =
      chars
      |> Enum.reduce({fb, x}, fn ch, {fb, cx} ->
        {draw_char(fb, cx, y, ch, fg, bg, scale), cx + 6 * scale}
      end)
      |> elem(0)

    {fb, length(chars) * 6 * scale}
  end

  def text_width(text, scale), do: String.length(text) * 6 * scale
  def text_height(scale), do: 7 * scale

  @doc "Write the whole shadow frame as ONE contiguous pwrite."
  def flush(%__MODULE__{rows: rows}, dev \\ "/dev/fb0") do
    frame = for y <- 0..(@height - 1), into: <<>>, do: Map.fetch!(rows, y)
    {:ok, fd} = :file.open(String.to_charlist(dev), [:write, :raw, :binary])
    :ok = :file.pwrite(fd, 0, frame)
    :file.close(fd)
    :ok
  end

  # --- internals ---

  defp draw_char(%__MODULE__{rows: rows} = fb, x, y, ch, fg, bg, scale) do
    glyph = HelloKioskBrain.Font.glyph(ch)

    new_rows =
      glyph
      |> Enum.with_index()
      |> Enum.reduce(rows, fn {bits, ry}, acc ->
        line = glyph_row_binary(bits, fg, bg, scale)

        Enum.reduce(0..(scale - 1), acc, fn sy, acc ->
          stamp(acc, x, y + ry * scale + sy, line)
        end)
      end)

    %{fb | rows: new_rows}
  end

  # 6 columns (5 glyph + 1 spacer), each `scale` px wide, as one binary.
  defp glyph_row_binary(bits, fg, bg, scale) do
    for col <- 0..5, into: <<>> do
      on = col < 5 and Bitwise.band(Bitwise.bsr(bits, 4 - col), 1) == 1
      :binary.copy(if(on, do: fg, else: bg), scale)
    end
  end

  # Overwrite a horizontal run at (x,y) in the rows map with `line`.
  defp stamp(rows, x, y, line) when y >= 0 and y < @height do
    px = x * @bpp
    lw = byte_size(line)

    if px >= 0 and px + lw <= @stride do
      <<pre::binary-size(^px), _::binary-size(^lw), post::binary>> = Map.fetch!(rows, y)
      Map.put(rows, y, <<pre::binary, line::binary, post::binary>>)
    else
      rows
    end
  end

  defp stamp(rows, _x, _y, _line), do: rows
end
