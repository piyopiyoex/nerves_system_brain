defmodule HelloKioskBrain.MemoDemo do
  @moduledoc """
  お絵描きメモ。タッチペンで手書きした線を、そのまま `/data/hello_kiosk/memo_strokes.bin` に記録する(1 画ごとに追記)。
  再起動しても、開くと前に描いたものがそのまま出る。下のボタンでペンの色(黒・赤・青)、「消去」で全消去、「戻る」で選択画面へ。

  入力は Input の `{:pen, :down | :move | :up, x, y}`(触れている間のサンプル)。抵抗膜のタッチパネルは押し始めと
  離す瞬間の座標がぶれるので、前の点と平均してなめらかにし、大きく飛んだ点は捨てる。描画はペンの動きごとではなく、
  たまった線分を 30 ms ごとにまとめて描く(1 回の描画に 20 ms ほどの固定の重さがあるため)。

  記録の形式: 1 画ごとに `<<長さ:32, term_to_binary({色, [{x, y}, ...]})>>` を追記。途中で電源が切れて末尾が
  壊れていても、読めたところまでを使う。
  """
  alias HelloKioskBrain.Draw

  @store "/data/hello_kiosk/memo_strokes.bin"
  @w 854
  @paper 0xF7F5EE
  @grid 0xE4E1D6
  @canvas_h 420
  @bar_y 426
  @colors [{0x1A1A1A, "黒"}, {0xD83A3A, "赤"}, {0x2E62D0, "青"}]
  @btn_h 48

  def init(_now) do
    %{strokes: load(), color: 0x1A1A1A, cur: nil, pending: []}
  end

  def full(s), do: [Draw.clear(@paper), paper(), Enum.map(s.strokes, &stroke_cmds/1), toolbar(s)]

  def frame(%{pending: []} = s, _now), do: {[], s, 30}
  def frame(s, _now), do: {Enum.reverse(s.pending), %{s | pending: []}, 30}

  # --- ペン(手書き) ---

  def pen(s, :down, x, y) when y < @canvas_h, do: %{s | cur: %{pts: [{x, y}], last: {x, y}}}
  def pen(s, :down, _x, _y), do: s

  def pen(%{cur: nil} = s, :move, _x, _y), do: s

  def pen(%{cur: cur} = s, :move, x, y) do
    {lx, ly} = cur.last
    # なめらかに(前の点と平均)。飛びすぎた点・紙の外は捨てる
    {nx, ny} = {div(lx + x, 2), min(div(ly + y, 2), @canvas_h - 2)}

    cond do
      abs(nx - lx) + abs(ny - ly) > 90 -> s
      abs(nx - lx) + abs(ny - ly) < 2 -> s
      true -> %{s | cur: %{pts: [{nx, ny} | cur.pts], last: {nx, ny}}, pending: [seg(lx, ly, nx, ny, s.color) | s.pending]}
    end
  end

  def pen(%{cur: nil} = s, :up, _x, _y), do: s

  def pen(%{cur: cur} = s, :up, _x, _y) do
    stroke = {s.color, Enum.reverse(cur.pts)}
    save(stroke)
    # 1 点だけ(トンと突いた)のときは点を打つ
    dot = if length(cur.pts) == 1, do: [stroke_cmds(stroke)], else: []
    %{s | strokes: s.strokes ++ [stroke], cur: nil, pending: dot ++ s.pending}
  end

  # --- ボタン(指を離した位置のタップ) ---

  def touch(s, x, y) when y >= @bar_y do
    case button_at(x) do
      {:color, c} -> {:ok, %{s | color: c}, toolbar(%{s | color: c})}
      :clear -> File.rm(@store); s = %{s | strokes: [], pending: []}; {:ok, s, full(s)}
      :back -> :exit
      nil -> {:ok, s, []}
    end
  end

  def touch(s, _x, _y), do: {:ok, s, []}

  defp button_at(x) do
    cond do
      x < 90 -> {:color, 0x1A1A1A}
      x < 180 -> {:color, 0xD83A3A}
      x < 270 -> {:color, 0x2E62D0}
      x >= 560 and x < 700 -> :clear
      x >= 714 -> :back
      true -> nil
    end
  end

  # --- 描画 ---

  defp paper do
    [
      for(y <- 40..(@canvas_h - 1)//40, do: Draw.line(0, y, @w - 1, y, @grid)),
      Draw.text(@w - 10, 10, :tr, :jp12, 0xA8A498, "お絵描きメモ(描いたものは自動で保存)")
    ]
  end

  defp toolbar(s) do
    [
      Draw.rect(0, @canvas_h, @w, 480 - @canvas_h, 0x1C2333),
      for {{c, name}, i} <- Enum.with_index(@colors) do
        x = 10 + i * 90
        [
          Draw.rrect(x, @bar_y, 76, @btn_h, 10, c),
          if(c == s.color, do: [Draw.rframe(x - 3, @bar_y - 3, 82, @btn_h + 6, 12, 0xFFC400), Draw.rframe(x - 2, @bar_y - 2, 80, @btn_h + 4, 11, 0xFFC400)], else: []),
          Draw.text(x + 38, @bar_y + div(@btn_h, 2), :mc, :jp20, 0xFFFFFF, name)
        ]
      end,
      Draw.text(300, @bar_y + div(@btn_h, 2), :ml, :jp16, 0x9FB4D0, "ペンの色"),
      Draw.rrect(560, @bar_y, 140, @btn_h, 10, 0x8A2A2A),
      Draw.text(630, @bar_y + div(@btn_h, 2), :mc, :jp24, 0xFFFFFF, "消去"),
      Draw.rrect(714, @bar_y, 130, @btn_h, 10, 0x34405A),
      Draw.text(779, @bar_y + div(@btn_h, 2), :mc, :jp24, 0xFFFFFF, "戻る")
    ]
  end

  defp stroke_cmds({color, [{x, y}]}), do: Draw.fcircle(x, y, 2, color)

  defp stroke_cmds({color, pts}) do
    for [{x1, y1}, {x2, y2}] <- Enum.chunk_every(pts, 2, 1, :discard), do: seg(x1, y1, x2, y2, color)
  end

  # 太さ 3 px の線(縦横にずらした 3 本)
  defp seg(x1, y1, x2, y2, c), do: [Draw.line(x1, y1, x2, y2, c), Draw.line(x1 + 1, y1, x2 + 1, y2, c), Draw.line(x1, y1 + 1, x2, y2 + 1, c)]

  # --- 記録 ---

  defp save(stroke) do
    bin = :erlang.term_to_binary(stroke)
    File.mkdir_p!(Path.dirname(@store))
    File.write(@store, <<byte_size(bin)::32, bin::binary>>, [:append])
  end

  defp load do
    case File.read(@store) do
      {:ok, bin} -> parse(bin, [])
      _ -> []
    end
  end

  defp parse(<<n::32, bin::binary-size(n), rest::binary>>, acc) do
    case safe_term(bin) do
      {c, pts} = st when is_integer(c) and is_list(pts) -> parse(rest, [st | acc])
      _ -> Enum.reverse(acc)
    end
  end

  defp parse(_, acc), do: Enum.reverse(acc)

  defp safe_term(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    _ -> nil
  end
end
