defmodule HelloKioskBrain.PapapaDemo do
  @moduledoc """
  「パパパの二重唱」デモ(モーツァルト「魔笛」より)。hello_kiosk_papapa(Raspberry Pi 3 版)の画面と
  タイムラインを PW-SH6(854×480、ARM926)向けに移したもの。

  スタックチャン風の 2 キャラクタ(パパゲーノ=緑・左 / パパゲーナ=ピンク・右)を描画コマンドだけで描き、
  伴奏つきの二重唱(`priv/audio/papapa/duet.wav`、48kHz ステレオ約 39 秒)に合わせて口パクと字幕を出す。
  口パク・字幕は `duet_timeline.term`(母艦で `scripts/gen_papapa_assets.py` が JSON から変換)で駆動する。

  ARM926 では全面描画が約 70 ms かかるので、通常の更新は**キャラクターと字幕の部分だけ**を描き直す
  (`update/2`)。しかも口・字幕の状態が変わったときと、イントロの震えの切替(150 ms)のときだけ描く。
  全面描画(`full/2`)は開始時だけ。再生開始時刻(`Audio` の `:audio_file_started`)を基準に、
  `at/2` で各パートの口と字幕を求める。再生開始の遅れの補正は `sync_offset_ms/0`(設定 `:papa_off`、既定 0)。
  """
  alias HelloKioskBrain.{Draw, Mixer}

  @w 854
  @bg 0x102030
  @geno_cx 237
  @gena_cx 617
  @face_cy 240
  @geno %{body: 0x2E8B57, accent: 0x9ACD32, name: "パパゲーノ", label: 0x7FE0A0}
  @gena %{body: 0xE87A9B, accent: 0xFFC0CB, name: "パパゲーナ", label: 0xFFB0C8}
  @wob_ms 150
  @subtitle_hold_ms 250

  @vocab_text %{
    "pa_staccato" => "パッ",
    "pa" => "パ",
    "pa_long" => "パー",
    "papageno" => "パパゲーノ",
    "papagena" => "パパゲーナ",
    "papageno_call" => "パパゲーノー！",
    "papagena_call" => "パパゲーナー！",
    "geno" => "ゲーノ！",
    "gena" => "ゲーナ！",
    "pa_legato" => "パ",
    "pageno" => "パゲーノ！",
    "pagena" => "パゲーナ！"
  }

  @key {__MODULE__, :timeline}

  @doc "二重唱の WAV のパス。"
  def wav_path, do: Path.join([:code.priv_dir(:hello_kiosk_brain), "audio", "papapa", "duet.wav"])

  @doc "素材(WAV とタイムライン)が揃っているか。無い機体ではデモの項目を押せなくする。"
  def available?, do: File.exists?(wav_path()) and File.exists?(timeline_path())

  defp timeline_path, do: Path.join([:code.priv_dir(:hello_kiosk_brain), "audio", "papapa", "duet_timeline.term"])

  @doc "再生開始の遅れの補正(ミリ秒)。設定 `:papa_off`(実聴で決める。正なら字幕・口を遅らせる)。"
  def sync_offset_ms, do: Mixer.get_setting(:papa_off, 0)

  @doc "タイムラインを読む(読み込みは 1 回だけ、以後は :persistent_term)。読めなければ nil。"
  def timeline do
    case :persistent_term.get(@key, nil) do
      nil ->
        with {:ok, [%{events: events, duration_ms: dur}]} <- :file.consult(String.to_charlist(timeline_path())) do
          events =
            events
            |> Enum.map(fn e -> Map.put(e, :text, Map.get(@vocab_text, e.vocab, e.vocab)) end)
            |> Enum.sort_by(& &1.t)

          tl = %{events: events, duration_ms: dur, intro_end_ms: (List.first(events) || %{t: 0}).t}
          :persistent_term.put(@key, tl)
          tl
        else
          _ -> nil
        end

      tl ->
        tl
    end
  end

  @doc """
  時刻 `t_ms` の各パートの状態 `%{male: %{mouth:, text:}, female: …}`。
  口: イベント区間の前半 70% = `:open`、残り = `:half`、区間外 = `:closed`。字幕は終了後も 250 ms 残す。
  """
  def at(%{events: events}, t_ms) do
    for part <- [:male, :female], into: %{} do
      mine = Enum.filter(events, &(&1.part == part))
      active = Enum.find(mine, fn e -> t_ms >= e.t and t_ms < e.t + e.dur end)
      recent = active || Enum.find(mine, fn e -> t_ms >= e.t and t_ms < e.t + e.dur + @subtitle_hold_ms end)

      mouth =
        case active do
          nil -> :closed
          e -> if t_ms < e.t + e.dur * 0.7, do: :open, else: :half
        end

      {part, %{mouth: mouth, text: recent && recent.text}}
    end
  end

  @doc "歌い出しまで(ピアノのイントロ)か。この間キャラは緊張の面持ち。"
  def nervous?(%{intro_end_ms: intro}, t_ms), do: t_ms < intro

  @doc "震えの位相(0 | 1)。イントロ中だけ 150 ms ごとに切り替わる。"
  def wob(t_ms), do: rem(div(max(t_ms, 0), @wob_ms), 2)

  @doc "描き直す必要があるかの目印。同じなら前回の描画のままでよい。"
  def sig(parts, nervous, wob) do
    {parts.male.mouth, parts.male.text, parts.female.mouth, parts.female.text, nervous, if(nervous, do: wob, else: 0)}
  end

  @doc "全面描画(開始時)。"
  def full(parts, opts), do: [Draw.clear(@bg), title(), credit_line(), update(parts, opts)]

  @doc "キャラクターと字幕だけの部分描画。`opts`: `%{nervous: boolean, wob: 0 | 1}`。"
  def update(parts, opts) do
    nervous = Map.get(opts, :nervous, false)
    wob = Map.get(opts, :wob, 0)
    expr = if nervous, do: :nervous, else: :normal
    # 震え: 2 キャラを逆位相で ±1px ずらす
    dx = if nervous, do: wob * 2 - 1, else: 0

    [
      # 前のコマを消す(キャラの領域と字幕の帯だけ)
      Draw.rect(@geno_cx - 130, @face_cy - 145, 260, 300, @bg),
      Draw.rect(@gena_cx - 130, @face_cy - 145, 260, 300, @bg),
      Draw.rect(@geno_cx - 200, 404, 400, 52, @bg),
      Draw.rect(@gena_cx - 200, 404, 400, 52, @bg),
      face(@geno_cx + dx, @face_cy, @geno, %{mouth: parts.male.mouth, blink: false, expr: expr}),
      face(@gena_cx - dx, @face_cy, @gena, %{mouth: parts.female.mouth, blink: false, expr: expr}),
      subtitle(@geno_cx, parts.male.text, @geno.label),
      subtitle(@gena_cx, parts.female.text, @gena.label)
    ]
  end

  @doc "キャラクター 1 体を描く(ほかのデモからも使う)。who: :geno | :gena、mouth: :closed | :half | :open。"
  def character(who, cx, cy, mouth, expr \\ :normal) do
    face(cx, cy, if(who == :geno, do: @geno, else: @gena), %{mouth: mouth, blink: false, expr: expr})
  end

  # 開始前・読み込み中の静止画(口は閉じて、緊張の表情)
  def idle_parts, do: %{male: %{mouth: :closed, text: nil}, female: %{mouth: :closed, text: nil}}

  defp title, do: Draw.text(div(@w, 2), 10, :tc, :jp20, 0x90A8C0, "パパパの二重唱")

  # 再生中はいつも歌声のクレジット(CC BY 3.0)を画面の下端に出す(詳細は「デモ」→「クレジット」)
  defp credit_line,
    do: Draw.text(div(@w, 2), 466, :mc, :jp12, 0x7088A0, "歌声: NIT ATR503 M001 / Mei (名古屋工業大学, CC BY 3.0)  ・  曲: モーツァルト「魔笛」(パブリックドメイン)")

  defp subtitle(_cx, nil, _color), do: []
  defp subtitle(cx, text, color), do: Draw.text(cx, 408, :tc, :jp32, color, text)

  # 歌唱中(口が開いている)は少し跳ねる
  defp face(cx, cy, theme, %{mouth: mouth, blink: blink, expr: expr}) do
    y = cy + if(mouth == :closed, do: 0, else: -8)

    [
      # 筐体(スタックチャン風の角丸ボディ) + 顔パネル
      Draw.rrect(cx - 110, y - 105, 220, 210, 24, theme.body),
      Draw.rrect(cx - 94, y - 89, 188, 178, 16, 0x14141C),
      # 頭の飾り(羽根)
      Draw.fcircle(cx - 40, y - 112, 12, theme.accent),
      Draw.fcircle(cx, y - 118, 14, theme.body),
      Draw.fcircle(cx + 40, y - 112, 12, theme.accent),
      eyes(cx, y, blink, expr),
      # ほほ
      Draw.fcircle(cx - 62, y + 14, 9, theme.accent),
      Draw.fcircle(cx + 62, y + 14, 9, theme.accent),
      mouth(cx, y + 44, mouth, expr),
      sweat(cx, y, expr),
      Draw.text(cx, y + 120, :tc, :jp20, theme.label, theme.name)
    ]
  end

  defp eyes(cx, y, true, _expr) do
    [Draw.rect(cx - 58, y - 32, 36, 5, 0xFFFFFF), Draw.rect(cx + 22, y - 32, 36, 5, 0xFFFFFF)]
  end

  defp eyes(cx, y, false, expr) do
    # 緊張中は瞳が相手の方(画面中央)へ寄る
    gaze = if expr == :nervous, do: if(cx < div(@w, 2), do: 9, else: -9), else: 0

    [
      Draw.fcircle(cx - 40, y - 30, 24, 0xFFFFFF),
      Draw.fcircle(cx + 40, y - 30, 24, 0xFFFFFF),
      Draw.fcircle(cx - 40 + gaze, y - 26, 10, 0x14141C),
      Draw.fcircle(cx + 40 + gaze, y - 26, 10, 0x14141C)
    ]
  end

  # 緊張中の閉じ口は「への字」
  defp mouth(cx, y, :closed, :nervous) do
    [
      Draw.line(cx - 18, y + 4, cx, y - 4, 0xFFFFFF),
      Draw.line(cx, y - 4, cx + 18, y + 4, 0xFFFFFF),
      Draw.line(cx - 18, y + 5, cx, y - 3, 0xFFFFFF),
      Draw.line(cx, y - 3, cx + 18, y + 5, 0xFFFFFF)
    ]
  end

  defp mouth(cx, y, :closed, _), do: Draw.rrect(cx - 26, y - 3, 52, 7, 3, 0xFFFFFF)
  defp mouth(cx, y, :half, _), do: Draw.rrect(cx - 26, y - 10, 52, 22, 10, 0xFFFFFF)
  defp mouth(cx, y, :open, _), do: [Draw.fcircle(cx, y, 24, 0xFFFFFF), Draw.fcircle(cx, y + 6, 14, 0xE05060)]

  # 汗マーク(こめかみ付近に水色のしずく)
  defp sweat(cx, y, :nervous), do: [Draw.fcircle(cx + 76, y - 66, 7, 0x9AD8F0), Draw.fcircle(cx + 76, y - 74, 4, 0x9AD8F0)]
  defp sweat(_cx, _y, _expr), do: []
end
