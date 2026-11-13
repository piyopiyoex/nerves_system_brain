defmodule HelloKioskBrain.FireworksDemo do
  @moduledoc """
  花火のデモ。夜の街並みの上に、ロケットが上がって色とりどりの火花に開く(重力・空気抵抗・色の減衰つき)。
  `init/1`・`full/1`・`frame/2` は「デモ」の汎用ランナー(Kiosk の `:anim` 画面)が呼ぶ。
  """
  alias HelloKioskBrain.Draw

  @w 854
  @h 480
  @bg 0x03050C
  @ground_y 420
  @colors [0xFF5A5A, 0xFFD24A, 0x5AE0FF, 0x9B6BFF, 0x6BFF8A, 0xFF8AE0, 0xFFFFFF, 0xFF9A3A]
  @max_sparks 220

  def init(now) do
    :rand.seed(:exsss, {now, 7, 11})
    %{last: now, next: now + 300, rockets: [], sparks: [], skyline: skyline()}
  end

  def full(s), do: [Draw.clear(@bg), scene(s)]

  def frame(s, now) do
    dt = min((now - s.last) / 1000.0, 0.2)
    s = %{s | last: now} |> launch(now) |> move(dt)
    {[Draw.rect(0, 0, @w, @ground_y, @bg), scene(s)], s, 0}
  end

  defp launch(%{next: next} = s, now) when now < next, do: s

  defp launch(s, now) do
    r = %{x: 120 + :rand.uniform(@w - 240) * 1.0, y: @ground_y * 1.0, vy: -(300 + :rand.uniform(120)) * 1.0,
          top: 70 + :rand.uniform(150), color: Enum.random(@colors)}
    HelloKioskBrain.Audio.play("fireworks/whistle")
    %{s | rockets: [r | s.rockets], next: now + 500 + :rand.uniform(900)}
  end

  defp move(s, dt) do
    {burst, flying} =
      s.rockets
      |> Enum.map(fn r -> %{r | y: r.y + r.vy * dt, vy: r.vy + 90 * dt} end)
      |> Enum.split_with(fn r -> r.y <= r.top or r.vy > -40 end)

    new = Enum.flat_map(burst, &explode/1)
    if burst != [], do: HelloKioskBrain.Audio.play("fireworks/boom#{:rand.uniform(3)}")

    sparks =
      (s.sparks ++ new)
      |> Enum.map(fn p ->
        drag = :math.pow(0.35, dt)
        %{p | x: p.x + p.vx * dt, y: p.y + p.vy * dt, vx: p.vx * drag, vy: p.vy * drag + 70 * dt, life: p.life - dt}
      end)
      |> Enum.filter(&(&1.life > 0 and &1.y < @ground_y))
      |> Enum.take(-@max_sparks)

    %{s | rockets: flying, sparks: sparks}
  end

  defp explode(r) do
    n = 26 + :rand.uniform(14)
    speed = 110 + :rand.uniform(80)
    two = if :rand.uniform(3) == 1, do: Enum.random(@colors), else: r.color

    for i <- 1..n do
      a = 2 * :math.pi() * i / n + :rand.uniform() * 0.2
      v = speed * (0.75 + :rand.uniform() * 0.35)
      %{x: r.x, y: r.y, vx: v * :math.cos(a), vy: v * :math.sin(a), life: 1.4 + :rand.uniform() * 0.8, max: 2.2,
        color: if(rem(i, 3) == 0, do: two, else: r.color)}
    end
  end

  defp scene(s) do
    [
      for r <- s.rockets do
        [Draw.line(round(r.x), round(r.y), round(r.x), round(r.y + 14), 0xFFE0A0), Draw.fcircle(round(r.x), round(r.y), 2, 0xFFFFFF)]
      end,
      for p <- s.sparks do
        k = min(p.life / 1.6, 1.0)
        Draw.fcircle(round(p.x), round(p.y), if(k > 0.6, do: 2, else: 1), fade(p.color, k))
      end,
      s.skyline,
      Draw.text(@w - 12, 14, :tr, :jp16, 0x6070A0, "花火 ・ タッチで戻る")
    ]
  end

  # 街並みのシルエット(窓の明かりつき)。開始時に 1 回だけ作る
  defp skyline do
    {bs, _} =
      Enum.map_reduce(1..22, 0, fn i, x ->
        w = 26 + rem(i * 37, 30)
        h = 40 + rem(i * 53, 90)
        windows =
          for wy <- (@ground_y - h + 8)..(@ground_y - 10)//14, wx <- (x + 5)..(x + w - 9)//10, rem(wx * 7 + wy * 3, 5) == 0 do
            Draw.rect(wx, wy, 4, 6, 0xC8A84A)
          end

        {[Draw.rect(x, @ground_y - h, w - 2, h, 0x0B0F1E), windows], x + w}
      end)

    [bs, Draw.rect(0, @ground_y, @w, @h - @ground_y, 0x080B16)]
  end

  defp fade(color, k) do
    import Bitwise
    r = (color >>> 16 &&& 0xFF) * k
    g = (color >>> 8 &&& 0xFF) * k
    b = (color &&& 0xFF) * k
    (round(r) <<< 16) ||| (round(g) <<< 8) ||| round(b)
  end
end
