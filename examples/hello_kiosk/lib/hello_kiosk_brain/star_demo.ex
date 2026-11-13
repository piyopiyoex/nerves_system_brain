defmodule HelloKioskBrain.StarDemo do
  @moduledoc """
  プラネタリウムのデモ。東京(北緯 35.68°、東経 139.77°)の、いまの星空を早回し(1 秒 = 2 分)で回す。
  4 等級までの恒星 519 個と星座線(d3-celestial、BSD 3-Clause)を、天頂を中心にした全天の円(上 = 北、左 = 東)に描く。
  恒星時から各星の高度・方位を求め、地平線より上だけを描く。
  """
  alias HelloKioskBrain.Draw

  @w 854
  @cx 427
  @cy 244
  @r 206
  @lat 35.68
  @lon 139.77
  @speed 120
  @key {__MODULE__, :cat}

  def init(now), do: %{t0: now, base: System.os_time(:millisecond)}

  def full(s), do: [Draw.clear(0x02030A), frame_cmds(s, s.t0)]

  def frame(s, now), do: {frame_cmds(s, now), s, 60}

  defp catalog do
    case :persistent_term.get(@key, nil) do
      nil ->
        path = Path.join([:code.priv_dir(:hello_kiosk_brain), "demo", "stars.term"])
        {:ok, [%{stars: stars, lines: lines}]} = :file.consult(String.to_charlist(path))
        prep = fn ra, dec -> {rad(ra), :math.sin(rad(dec)), :math.cos(rad(dec))} end
        c = %{stars: for({ra, dec, mag} <- stars, do: {prep.(ra, dec), mag}), lines: for(l <- lines, do: for({ra, dec} <- l, do: prep.(ra, dec)))}
        :persistent_term.put(@key, c)
        c

      c ->
        c
    end
  end

  defp frame_cmds(s, now) do
    c = catalog()
    ms = s.base + (now - s.t0) * @speed
    jd = ms / 86_400_000 + 2_440_587.5
    lst = rad(norm(280.46061837 + 360.98564736629 * (jd - 2_451_545.0) + @lon))
    {sl, cl} = {:math.sin(rad(@lat)), :math.cos(rad(@lat))}
    proj = fn {ra, sd, cd} -> project(lst - ra, sd, cd, sl, cl) end

    lines =
      for l <- c.lines, [a, b] <- Enum.chunk_every(l, 2, 1, :discard), pa = proj.(a), pb = proj.(b), pa != nil and pb != nil do
        Draw.line(elem(pa, 0), elem(pa, 1), elem(pb, 0), elem(pb, 1), 0x2A4470)
      end

    stars =
      for {p, mag} <- c.stars, xy = proj.(p), xy != nil do
        {x, y} = xy
        cond do
          mag < 0.6 -> Draw.fcircle(x, y, 3, 0xFFFFFF)
          mag < 1.6 -> Draw.fcircle(x, y, 2, 0xF0F4FF)
          mag < 2.6 -> Draw.fcircle(x, y, 1, 0xD0DCF0)
          true -> Draw.rect(x, y, 1, 1, 0x9AA8C0)
        end
      end

    jst = DateTime.from_unix!(round(ms), :millisecond) |> DateTime.add(9 * 3600, :second)

    [
      Draw.fcircle(@cx, @cy, @r, 0x060C22),
      Draw.circle(@cx, @cy, @r, 0x3A4A6A),
      lines,
      stars,
      for {t, x, y} <- [{"北", @cx, @cy - @r - 12}, {"南", @cx, @cy + @r + 12}, {"東", @cx - @r - 14, @cy}, {"西", @cx + @r + 14, @cy}] do
        Draw.text(x, y, :mc, :jp16, 0xC8A050, t)
      end,
      Draw.rect(0, 0, 250, 60, 0x02030A),
      Draw.text(14, 16, :ml, :jp20, 0xE8EEF5, "東京の星空"),
      Draw.text(14, 42, :ml, :jp16, 0x9FB4D0, Calendar.strftime(jst, "%Y-%m-%d %H:%M")),
      Draw.text(@w - 14, 16, :mr, :jp16, 0x7088A0, "早回し ×#{@speed}(1 秒 = 2 分)"),
      Draw.text(@w - 14, 466, :mr, :jp12, 0x5A6A80, "星表・星座線: d3-celestial (BSD) ・ タッチで戻る")
    ]
  end

  # 時角 H、赤緯(sin, cos)から高度・方位を出し、天頂中心の等距離図法で画面に置く。地平線より下は nil
  defp project(h, sd, cd, sl, cl) do
    salt = sl * sd + cl * cd * :math.cos(h)

    if salt <= 0 do
      nil
    else
      alt = :math.asin(salt)
      az = :math.atan2(-cd * :math.sin(h), sd * cl - cd * sl * :math.cos(h))
      r = (1 - alt / (:math.pi() / 2)) * @r
      {round(@cx - r * :math.sin(az)), round(@cy - r * :math.cos(az))}
    end
  end

  defp norm(d), do: d - 360.0 * Float.floor(d / 360.0)
  defp rad(d), do: d * :math.pi() / 180
end
