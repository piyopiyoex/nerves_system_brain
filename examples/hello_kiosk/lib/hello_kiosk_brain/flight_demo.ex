defmodule HelloKioskBrain.FlightDemo do
  @moduledoc """
  フライトシミュレータ風のデモ画面(PFD: プライマリ・フライト・ディスプレイ)。

  オートパイロットが旋回・上昇・降下を繰り返す飛行を、描画コマンドだけで表示する:

    * 中央の窓(614×380): 水平線(空と地面)、遠近感のある地面の格子、ピッチラダー、ロール目盛り、機体シンボル
    * 左: 速度テープ(IAS)/ 右: 高度テープ + 昇降計(V/S)/ 下: 方位テープ / 上: フライトモード表示(FMA)

  外の景色は 3D の射影(焦点距離 `@f` ピクセルのピンホール)で求め、機体の姿勢(ロール・ピッチ・方位)と位置から
  地面の格子線を描く。水平線は縦の短冊(幅 `@sw` px)の塗り分けで描く(NIF に多角形の塗りが無いため)。
  窓の外にはみ出す線は `clip/2` で窓に切り詰める(NIF にクリップ設定が無いため)。

  ARM926 の全面描画は重いので、姿勢の窓は毎コマ、テープなどの計器は数コマに 1 回だけ描き直す(`instruments/1`)。
  シミュレーションは時刻 `t` の決まった関数(`step/2`)で、乱れ(乱気流)を少し足す。
  """
  alias HelloKioskBrain.Draw

  @w 854
  # 姿勢の窓
  @wx 120
  @wy 40
  @ww 614
  @wh 380
  @cx 427
  @cy 230
  # 焦点距離(px)。1°≒5.8px、窓の縦は約 ±33°
  @f 330.0
  # 地面の格子
  @grid_g 400.0
  @grid_range 3000.0
  @near 20.0

  @panel 0x0E141C
  @fg 0xE8EEF5
  @dim 0x7C8CA0
  @amber 0xFFC400
  @green 0x39E36B
  @mag 0xF050D0
  @grid_near 0x6F7E49
  @grid_mid 0x5F6C3F

  @doc "シミュレーションの初期状態。`now_ms` は単調時計(ms)。"
  def new(now_ms) do
    %{t: 0.0, psi: 40.0, alt: 3200.0, spd: 235.0, roll: 0.0, pitch: 0.0, vs: 0.0, x: 0.0, y: 0.0, last: now_ms,
      frames: 0, fps: 0, fps_t: now_ms, fps_n: 0, inst_at: -1_000}
  end

  @doc "シミュレーションを `now_ms` まで進める(時刻の決まった関数 + 微小な乱れ)。"
  def step(sim, now_ms) do
    dt = min((now_ms - sim.last) / 1000.0, 0.25)
    t = sim.t + dt
    tau = 2 * :math.pi()
    spd = 235.0 + 12.0 * :math.sin(tau * t / 47.0)
    roll_t = 24.0 * :math.sin(tau * t / 38.0) * (0.55 + 0.45 * :math.sin(tau * t / 101.0))
    pitch_t = 1.6 + 3.8 * :math.sin(tau * t / 29.0 + 1.0)
    roll = roll_t + 0.6 * :math.sin(t * 6.9) + 0.35 * :math.sin(t * 13.1)
    pitch = pitch_t + 0.35 * :math.sin(t * 5.3) + 0.2 * :math.sin(t * 11.7)
    v = spd * 0.5144
    psi = norm360(sim.psi + 9.81 * :math.tan(rad(roll_t)) / v * 57.2958 * dt)
    vs_ms = v * :math.sin(rad(pitch_t - 1.6))
    alt = max(sim.alt + vs_ms * 3.28084 * dt, 800.0)

    %{sim | t: t, psi: psi, alt: alt, spd: spd, roll: roll, pitch: pitch, vs: vs_ms * 196.85,
      x: sim.x + v * dt * :math.sin(rad(psi)), y: sim.y + v * dt * :math.cos(rad(psi)), last: now_ms}
  end

  @doc "コマ数(1 秒ごとに fps を更新)を数える。"
  def tick_frame(sim, now_ms) do
    sim = %{sim | frames: sim.frames + 1, fps_n: sim.fps_n + 1}

    if now_ms - sim.fps_t >= 1000,
      do: %{sim | fps: sim.fps_n, fps_n: 0, fps_t: now_ms},
      else: sim
  end

  @doc "計器(テープなど)を描き直す時期か。"
  def instruments_due?(sim, now_ms), do: now_ms - sim.inst_at >= 280

  @doc "全面描画(開始時)。"
  def full(sim), do: [Draw.clear(@panel), instruments(sim), attitude(sim)]

  # --- 姿勢の窓 -----------------------------------------------------------------

  @doc "姿勢の窓(水平線・地面の格子・ピッチラダー・ロール目盛り・機体シンボル)の描画コマンド。"
  def attitude(sim) do
    th = rad(sim.pitch)
    phi = rad(sim.roll)
    {s, c} = {:math.sin(phi), :math.cos(phi)}
    oy = @f * :math.tan(th)
    {hx, hy} = {@cx + oy * s, @cy + oy * c}

    [
      sky_ground(hx, hy, s, c),
      grid(sim, s, c),
      horizon_line(oy, s, c),
      ladder(sim.pitch, s, c),
      roll_scale(sim.roll, s, c),
      aircraft_symbol(),
      Draw.frame(@wx, @wy, @ww, @wh, 0x000000)
    ]
  end

  # 空と地面を、水平線からの距離ごとの帯(遠いほど濃く)の多角形で塗る。窓の矩形を半平面で切り、三角形の扇で描く。
  # 「水平線から d px 以上」の領域を、水平線に近い方から順に重ね塗りする(隣の帯との隙間ができない)
  @ground_bands [{0, 0x8A9163}, {24, 0x6A7642}, {70, 0x5A6634}, {150, 0x4E5A2E}, {260, 0x434D28}]
  @sky_bands [{0, 0x9CC8EE}, {16, 0x6BA6E0}, {50, 0x4A89D4}, {110, 0x2F6EC4}, {190, 0x1F5FBF}]

  defp sky_ground(hx, hy, s, c) do
    win = [{@wx, @wy}, {@wx + @ww, @wy}, {@wx + @ww, @wy + @wh}, {@wx, @wy + @wh}]
    # 水平線の符号つき距離 d(p) = (p - H)·n。n = (sinφ, cosφ) は地面の側(下)を向く
    base = hx * s + hy * c

    sky =
      for {up, color} <- @sky_bands do
        fan(clip_half(win, -s, -c, base - up), color)
      end

    ground =
      for {down, color} <- @ground_bands do
        fan(clip_half(win, s, c, -base - down), color)
      end

    [sky, ground]
  end

  # 凸多角形を三角形の扇にして塗る
  defp fan([{x0, y0} | [_, _ | _] = rest], color) do
    for [{x1, y1}, {x2, y2}] <- Enum.chunk_every(rest, 2, 1, :discard) do
      Draw.tri(round(x0), round(y0), round(x1), round(y1), round(x2), round(y2), color)
    end
  end

  defp fan(_, _), do: []

  # Sutherland–Hodgman: 半平面 a·x + b·y + k >= 0 の側だけを残す
  defp clip_half(poly, a, b, k) do
    pairs = Enum.zip(poly, tl(poly) ++ [hd(poly)])

    Enum.flat_map(pairs, fn {{x1, y1}, {x2, y2}} ->
      d1 = a * x1 + b * y1 + k
      d2 = a * x2 + b * y2 + k
      t = if d1 == d2, do: 0.0, else: d1 / (d1 - d2)
      cross = {x1 + (x2 - x1) * t, y1 + (y2 - y1) * t}

      cond do
        d1 >= 0 and d2 >= 0 -> [{x2, y2}]
        d1 >= 0 -> [cross]
        d2 >= 0 -> [cross, {x2, y2}]
        true -> []
      end
    end)
  end

  defp horizon_line(oy, s, c) do
    {x1, y1} = rot(-500.0, oy, s, c)
    {x2, y2} = rot(500.0, oy, s, c)
    [seg(x1, y1, x2, y2, @fg), seg(x1, y1 + 1, x2, y2 + 1, @fg)]
  end

  # 地面の格子(東西・南北の線)。機体の位置・方位・高度・ピッチから射影して、遠いほど地面に溶けるように描く
  defp grid(sim, s, c) do
    cam = camera(sim)
    gx = floor(sim.x / @grid_g)
    gy = floor(sim.y / @grid_g)
    n = ceil(@grid_range / @grid_g)

    ew = for k <- (gy - n)..(gy + n), do: {{sim.x - @grid_range, k * @grid_g}, {sim.x + @grid_range, k * @grid_g}}
    ns = for k <- (gx - n)..(gx + n), do: {{k * @grid_g, sim.y - @grid_range}, {k * @grid_g, sim.y + @grid_range}}

    for {{ax, ay}, {bx, by}} <- ew ++ ns do
      with {:ok, {u1, v1, z1}, {u2, v2, z2}} <- project_segment(cam, ax, ay, bx, by) do
        color = if min(z1, z2) < 900, do: @grid_near, else: @grid_mid
        {x1, y1} = rot(u1, v1, s, c)
        {x2, y2} = rot(u2, v2, s, c)
        seg(x1, y1, x2, y2, color)
      else
        _ -> []
      end
    end
  end

  # 機体の姿勢から、カメラの向き(前・右・上)を求める
  defp camera(sim) do
    psi = rad(sim.psi)
    th = rad(sim.pitch)
    {sp, cp, st, ct} = {:math.sin(psi), :math.cos(psi), :math.sin(th), :math.cos(th)}

    %{
      p: {sim.x, sim.y, sim.alt * 0.3048},
      f: {sp * ct, cp * ct, st},
      r: {cp, -sp, 0.0},
      u: {-sp * st, -cp * st, ct}
    }
  end

  # 世界座標(東・北、地面の高さ 0)の線分を、カメラ手前の面で切って画面座標(窓の中心からの差 u,v と奥行き z)にする
  defp project_segment(cam, ax, ay, bx, by) do
    {px, py, pz} = cam.p
    {fx, fy, fz} = cam.f
    {rx, ry, _} = cam.r
    {ux, uy, uz} = cam.u
    da = {ax - px, ay - py, -pz}
    db = {bx - px, by - py, -pz}
    za = dot(da, {fx, fy, fz})
    zb = dot(db, {fx, fy, fz})

    cond do
      za < @near and zb < @near ->
        :skip

      true ->
        {da, za} = if za < @near, do: cut(da, db, za, zb), else: {da, za}
        {db, zb} = if zb < @near, do: cut(db, da, zb, za), else: {db, zb}
        {u1, v1} = screen(da, za, {rx, ry, 0.0}, {ux, uy, uz})
        {u2, v2} = screen(db, zb, {rx, ry, 0.0}, {ux, uy, uz})
        {:ok, {u1, v1, za}, {u2, v2, zb}}
    end
  end

  # 奥行きが @near 未満の端点を、@near の面まで線分上で寄せる
  defp cut({ax, ay, az}, {bx, by, bz}, za, zb) do
    t = (@near - za) / (zb - za)
    {{ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t}, @near}
  end

  defp screen(d, z, r, u) do
    {dot(d, r) * @f / z, -dot(d, u) * @f / z}
  end

  defp dot({a, b, c}, {d, e, f}), do: a * d + b * e + c * f

  # ピッチラダー(5° ごと。10° ごとは長く数字つき)。窓の外は切り詰め
  defp ladder(pitch, s, c) do
    for p <- -35..35//5, p != 0, abs(p - pitch) < 33 do
      dy = -@f * :math.tan(rad(p - pitch))
      half = if rem(p, 10) == 0, do: 46.0, else: 22.0
      {x1, y1} = rot(-half, dy, s, c)
      {x2, y2} = rot(half, dy, s, c)
      label = if rem(p, 10) == 0, do: Integer.to_string(abs(p)), else: nil

      [
        seg(x1, y1, x2, y2, @fg),
        if(label,
          do: [text_in(x1 - 14, y1, :mc, :jp12, @fg, label), text_in(x2 + 14, y2, :mc, :jp12, @fg, label)],
          else: []
        )
      ]
    end
  end

  # ロール目盛り(窓の上部。固定)と、バンク角の指針(水平線と一緒に回る側)
  defp roll_scale(_roll, s, c) do
    r = 160.0
    arc = for a <- -60..55//5, do: {a, a + 5}

    ticks = [-60, -45, -30, -20, -10, 0, 10, 20, 30, 45, 60]

    [
      for {a, b} <- arc do
        {x1, y1} = on_arc(r, a)
        {x2, y2} = on_arc(r, b)
        seg(x1, y1, x2, y2, @fg)
      end,
      for a <- ticks do
        len = if a in [0, 30, -30, 60, -60], do: 16, else: 9
        {x1, y1} = on_arc(r, a)
        {x2, y2} = on_arc(r + len, a)
        seg(x1, y1, x2, y2, @fg)
      end,
      # バンク角の指針: 目盛りの内側で、水平線と同じ向きに回る
      case rot(0.0, -(r - 6.0), s, c) do
        {px, py} ->
          {qx, qy} = rot(0.0, -(r - 22.0), s, c)
          [seg(px, py, qx, qy, @amber), seg(px + 1, py, qx + 1, qy, @amber), dot_in(qx, qy, 4, @amber)]
      end
    ]
  end

  defp on_arc(r, deg), do: {@cx + r * :math.sin(rad(deg)), @cy - r * :math.cos(rad(deg))}

  # 機体シンボル(固定、黄色)
  defp aircraft_symbol do
    [
      Draw.rect(@cx - 100, @cy - 4, 64, 8, 0x000000),
      Draw.rect(@cx + 36, @cy - 4, 64, 8, 0x000000),
      Draw.rect(@cx - 98, @cy - 2, 60, 4, @amber),
      Draw.rect(@cx + 38, @cy - 2, 60, 4, @amber),
      Draw.rect(@cx - 40, @cy - 2, 4, 14, @amber),
      Draw.rect(@cx + 36, @cy - 2, 4, 14, @amber),
      Draw.fcircle(@cx, @cy, 5, 0x000000),
      Draw.fcircle(@cx, @cy, 3, @amber)
    ]
  end

  # --- 計器(速度・高度・方位・フライトモード) -------------------------------------

  @doc "テープなどの計器の描画コマンド(数コマに 1 回描き直す)。"
  def instruments(sim) do
    [top_bar(sim), speed_tape(sim.spd), altitude_tape(sim.alt, sim.vs), heading_tape(sim.psi)]
  end

  defp top_bar(sim) do
    secs = trunc(sim.t)
    clock = :io_lib.format("T+~2..0w:~2..0w", [div(secs, 60), rem(secs, 60)]) |> IO.iodata_to_binary()

    [
      Draw.rect(0, 0, @w, 40, @panel),
      Draw.text(20, 20, :ml, :jp16, @dim, "FLT DEMO"),
      for {x, t, col} <- [{190, "SPD", @green}, {290, "HDG", @green}, {390, "ALT", @green}, {490, "V/S", @mag}, {590, "AP1+2", @fg}] do
        [Draw.rframe(x, 8, 84, 24, 4, @dim), Draw.text(x + 42, 20, :mc, :jp16, col, t)]
      end,
      Draw.text(@w - 20, 12, :mr, :jp16, @fg, clock),
      Draw.text(@w - 20, 30, :mr, :jp12, @dim, "#{sim.fps} fps")
    ]
  end

  # 左: 速度テープ。1 kt = 3.4 px、10 kt ごとの目盛り、20 kt ごとに数字
  defp speed_tape(spd) do
    ppk = 3.4
    lo = floor((spd - 60) / 10) * 10
    hi = ceil((spd + 60) / 10) * 10

    [
      Draw.rect(0, 40, 120, 380, @panel),
      for v <- lo..hi//10, v >= 0 do
        y = @cy - (v - spd) * ppk
        long = rem(v, 20) == 0

        if y > 100 and y < 360 do
          [
            Draw.line(if(long, do: 100, else: 108), round(y), 118, round(y), @fg),
            if(long, do: Draw.text(92, round(y), :mr, :jp16, @fg, Integer.to_string(v)), else: [])
          ]
        else
          []
        end
      end,
      Draw.rrect(8, @cy - 18, 90, 36, 4, 0x000000),
      Draw.rframe(8, @cy - 18, 90, 36, 4, @amber),
      Draw.text(53, @cy, :mc, :jp24, @fg, Integer.to_string(round(spd))),
      Draw.text(14, 52, :tl, :jp12, @dim, "IAS KT"),
      Draw.text(14, 404, :bl, :jp12, @mag, "TGT 235")
    ]
  end

  # 右: 高度テープ(1 ft = 0.38 px、100 ft ごとの目盛り、200 ft ごとに数字)と昇降計
  defp altitude_tape(alt, vs) do
    ppf = 0.38
    lo = floor((alt - 500) / 100) * 100
    hi = ceil((alt + 500) / 100) * 100

    [
      Draw.rect(734, 40, 120, 380, @panel),
      for v <- lo..hi//100, v >= 0 do
        y = @cy - (v - alt) * ppf
        long = rem(v, 200) == 0

        if y > 100 and y < 360 do
          [
            Draw.line(736, round(y), if(long, do: 752, else: 744), round(y), @fg),
            if(long, do: Draw.text(758, round(y), :ml, :jp16, @fg, Integer.to_string(v)), else: [])
          ]
        else
          []
        end
      end,
      Draw.rrect(756, @cy - 18, 94, 36, 4, 0x000000),
      Draw.rframe(756, @cy - 18, 94, 36, 4, @amber),
      Draw.text(803, @cy, :mc, :jp24, @fg, Integer.to_string(round(alt / 20) * 20)),
      Draw.text(840, 52, :tr, :jp12, @dim, "ALT FT"),
      Draw.text(840, 404, :br, :jp12, @dim, "QNH 1013"),
      Draw.text(746, 72, :ml, :jp12, @dim, "V/S FPM"),
      Draw.text(746, 90, :ml, :jp20, @green, vs_text(vs))
    ]
  end

  defp vs_text(vs) do
    v = round(vs / 50) * 50
    if v >= 0, do: "+#{v}", else: "#{v}"
  end

  # 下: 方位テープ(1° = 6 px、5° ごとの目盛り、10° ごとに数字。0/90/180/270 は N/E/S/W)
  defp heading_tape(psi) do
    ppd = 6.0
    lo = floor((psi - 52) / 5) * 5
    hi = ceil((psi + 52) / 5) * 5

    [
      Draw.rect(0, 420, @w, 60, @panel),
      for d <- lo..hi//5 do
        x = @cx + (d - psi) * ppd
        deg = Integer.mod(d, 360)
        long = rem(deg, 10) == 0

        if x > @wx + 6 and x < @wx + @ww - 6 do
          [
            Draw.line(round(x), 454, round(x), if(long, do: 466, else: 460), @fg),
            if(long, do: Draw.text(round(x), 465, :tc, :jp12, @fg, compass(deg)), else: [])
          ]
        else
          []
        end
      end,
      Draw.rrect(@cx - 38, 423, 76, 26, 4, 0x000000),
      Draw.rframe(@cx - 38, 423, 76, 26, 4, @amber),
      Draw.text(@cx, 436, :mc, :jp20, @fg, three(round(psi)) <> "°"),
      Draw.text(@wx + 10, 436, :ml, :jp12, @dim, "HDG"),
      Draw.text(@wx + @ww - 10, 436, :mr, :jp12, @mag, "SEL 290")
    ]
  end

  defp compass(0), do: "N"
  defp compass(90), do: "E"
  defp compass(180), do: "S"
  defp compass(270), do: "W"
  defp compass(d), do: three(div(d, 10))

  defp three(n) do
    n = Integer.mod(n, 360)
    n |> Integer.to_string() |> String.pad_leading(3, "0")
  end

  # --- 幾何の道具 -----------------------------------------------------------------

  # 窓の中心からの差(dx, dy)を、ロール φ だけ反時計回りに回して画面座標にする(右バンクで水平線の右が上がる)
  defp rot(dx, dy, s, c), do: {@cx + dx * c + dy * s, @cy - dx * s + dy * c}

  # 窓に切り詰めた線分(外に出ていれば何も描かない)
  defp seg(x1, y1, x2, y2, color) do
    case clip(x1, y1, x2, y2) do
      {a, b, c, d} -> Draw.line(round(a), round(b), round(c), round(d), color)
      nil -> []
    end
  end

  defp text_in(x, y, datum, font, color, string) do
    if x > @wx + 12 and x < @wx + @ww - 12 and y > @wy + 8 and y < @wy + @wh - 8,
      do: Draw.text(round(x), round(y), datum, font, color, string),
      else: []
  end

  defp dot_in(x, y, r, color) do
    if x > @wx and x < @wx + @ww and y > @wy and y < @wy + @wh, do: Draw.fcircle(round(x), round(y), r, color), else: []
  end

  # Liang–Barsky の線分クリップ(窓の矩形)
  defp clip(x1, y1, x2, y2) do
    dx = x2 - x1
    dy = y2 - y1
    xmin = @wx + 1
    xmax = @wx + @ww - 2
    ymin = @wy + 1
    ymax = @wy + @wh - 2

    with {:ok, t0, t1} <- clip_t(-dx, x1 - xmin, 0.0, 1.0),
         {:ok, t0, t1} <- clip_t(dx, xmax - x1, t0, t1),
         {:ok, t0, t1} <- clip_t(-dy, y1 - ymin, t0, t1),
         {:ok, t0, t1} <- clip_t(dy, ymax - y1, t0, t1) do
      {x1 + t0 * dx, y1 + t0 * dy, x1 + t1 * dx, y1 + t1 * dy}
    else
      _ -> nil
    end
  end

  defp clip_t(p, q, t0, t1) do
    cond do
      p == 0 -> if q < 0, do: :out, else: {:ok, t0, t1}
      p < 0 -> r = q / p; if r > t1, do: :out, else: {:ok, max(t0, r), t1}
      true -> r = q / p; if r < t0, do: :out, else: {:ok, t0, min(t1, r)}
    end
  end

  defp rad(d), do: d * :math.pi() / 180.0

  defp norm360(d) do
    d = :math.fmod(d, 360.0)
    if d < 0, do: d + 360.0, else: d
  end
end
