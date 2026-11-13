defmodule HelloKioskBrain.WorldDemo do
  @moduledoc """
  世界時計のデモ。世界地図(Natural Earth の陸地、210×105 セル)に、いまの昼・薄明・夜を色分けして重ね、
  主要都市の現地時刻と太陽の真下の位置を出す。昼夜の境目は太陽の赤緯と時角から行ごとに求める
  (各緯度で「日の出・日の入りの時角」を出して、経度と比べるだけなので、セルごとの三角関数は不要)。
  地図は 30 秒ごと、上の時計は毎秒描き直す。
  """
  alias HelloKioskBrain.Draw

  @w 854
  @x0 7
  @y0 36
  @cell 4
  @key {__MODULE__, :map}
  # {名前, 経度, 緯度, UTC からの時差(標準時)}
  @cities [{"東京", 139.7, 35.7, 9}, {"シドニー", 151.2, -33.9, 10}, {"シンガポール", 103.8, 1.3, 8}, {"ドバイ", 55.3, 25.2, 4},
           {"パリ", 2.35, 48.9, 1}, {"ロンドン", -0.13, 51.5, 0}, {"ニューヨーク", -74.0, 40.7, -5},
           {"ロサンゼルス", -118.2, 34.1, -8}, {"ホノルル", -157.9, 21.3, -10}, {"サンパウロ", -46.6, -23.5, -3}]
  # 色 {海, 陸} × {昼, 薄明, 夜}
  @col %{{:sea, 2} => 0x1E5A8C, {:sea, 1} => 0x143F66, {:sea, 0} => 0x0A1D33,
         {:land, 2} => 0x6A9440, {:land, 1} => 0x40602A, {:land, 0} => 0x1F3018}

  def init(_now), do: %{map_at: 0, sec: -1}

  def full(_s), do: [Draw.clear(0x05080F), map_layer(), clock_layer()]

  def frame(s, now) do
    sec = div(System.os_time(:second), 1)
    cond do
      now - s.map_at >= 30_000 -> {[map_layer(), clock_layer()], %{s | map_at: now, sec: sec}, 200}
      sec != s.sec -> {clock_layer(), %{s | sec: sec}, 200}
      true -> {[], s, 200}
    end
  end

  defp mask do
    case :persistent_term.get(@key, nil) do
      nil ->
        path = Path.join([:code.priv_dir(:hello_kiosk_brain), "demo", "world.term"])
        {:ok, [%{w: w, h: h, rows: rows}]} = :file.consult(String.to_charlist(path))

        m = %{w: w, h: h, rows: Enum.map(rows, fn runs -> for {a, l} <- runs, i <- a..(a + l - 1), into: MapSet.new(), do: i end)}
        :persistent_term.put(@key, m)
        m

      m ->
        m
    end
  end

  # 太陽の赤緯(簡易式)と、太陽の真下の経度
  defp sun do
    now = DateTime.utc_now()
    doy = Date.day_of_year(now)
    dec = -23.44 * :math.cos(2 * :math.pi() / 365 * (doy + 10))
    hours = now.hour + now.minute / 60 + now.second / 3600
    {dec, wrap(-15.0 * (hours - 12.0))}
  end

  defp map_layer do
    %{w: w, h: h, rows: rows} = mask()
    {dec, slon} = sun()
    d = rad(dec)

    cells =
      for {land, j} <- Enum.with_index(rows) do
        lat = rad(90 - (j + 0.5) * 180 / h)
        h0 = limit(-:math.tan(lat) * :math.tan(d))
        ht = limit((:math.sin(rad(-6)) - :math.sin(lat) * :math.sin(d)) / (:math.cos(lat) * :math.cos(d)))

        cats =
          for i <- 0..(w - 1) do
            ha = abs(wrap(-180 + (i + 0.5) * 360 / w - slon))
            light = cond do
              ha < h0 -> 2
              ha < ht -> 1
              true -> 0
            end

            {if(MapSet.member?(land, i), do: :land, else: :sea), light}
          end

        runs(cats, j)
      end

    {sx, sy} = to_xy(slon, dec)
    [cells, Draw.fcircle(sx, sy, 7, 0xFFD24A), Draw.circle(sx, sy, 11, 0xFFE58A), cities()]
  end

  # 行のセルの並びを、同じ色が続く区間の矩形にまとめる
  defp runs(cats, j) do
    y = @y0 + j * @cell

    cats
    |> Enum.chunk_by(& &1)
    |> Enum.reduce({[], 0}, fn chunk, {acc, i} ->
      n = length(chunk)
      {[Draw.rect(@x0 + i * @cell, y, n * @cell, @cell, @col[hd(chunk)]) | acc], i + n}
    end)
    |> elem(0)
  end

  # 時角の限界(度)。常に昼なら 180、常に夜なら 0
  defp limit(cosv) when cosv <= -1, do: 180.0
  defp limit(cosv) when cosv >= 1, do: 0.0
  defp limit(cosv), do: :math.acos(cosv) * 180 / :math.pi()

  defp cities do
    utc = DateTime.utc_now()

    for {name, lon, lat, off} <- @cities do
      {x, y} = to_xy(lon, lat)
      t = DateTime.add(utc, off * 3600, :second)
      hm = "#{String.pad_leading("#{t.hour}", 2, "0")}:#{String.pad_leading("#{t.minute}", 2, "0")}"
      # パリはロンドンと重なるので、名前を左側に出す
      {dx, datum} = if name == "パリ", do: {-6, :mr}, else: {6, :ml}
      [Draw.fcircle(x, y, 3, 0xFFFFFF), Draw.text(x + dx, y - 9, datum, :jp12, 0xFFFFFF, name), Draw.text(x + dx, y + 5, datum, :jp12, 0xFFE58A, hm)]
    end
  end

  defp clock_layer do
    utc = DateTime.utc_now()
    jst = DateTime.add(utc, 9 * 3600, :second)
    f = fn t -> Calendar.strftime(t, "%H:%M:%S") end

    [
      Draw.rect(0, 0, @w, 34, 0x05080F),
      Draw.text(14, 17, :ml, :jp20, 0xE8EEF5, "世界時計"),
      Draw.text(300, 17, :ml, :jp20, 0x9FB4D0, "UTC " <> f.(utc)),
      Draw.text(520, 17, :ml, :jp20, 0xFFE58A, "日本 " <> f.(jst)),
      Draw.text(@w - 12, 470, :br, :jp12, 0x5A6A80, "地図: Natural Earth / 昼・薄明・夜は太陽の位置から計算 ・ タッチで戻る")
    ]
  end

  defp to_xy(lon, lat), do: {round(@x0 + (lon + 180) / 360 * 210 * @cell), round(@y0 + (90 - lat) / 180 * 105 * @cell)}
  defp wrap(d), do: d - 360.0 * Float.floor((d + 180.0) / 360.0)
  defp rad(d), do: d * :math.pi() / 180
end
