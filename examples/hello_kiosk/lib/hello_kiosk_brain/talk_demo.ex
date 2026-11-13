defmodule HelloKioskBrain.TalkDemo do
  @moduledoc """
  おしゃべり時計のデモ。パパゲーナが、いまの時刻を声で知らせる(時報の音声素材 h/m を連結)。
  口は音声の大きさ(60 ms ごとの振幅)に合わせて動く。話し終えたら 8 秒後にまた話す。
  音は `Audio.render_seq/2` で 1 本の WAV にしてから `Audio.play_file/2` で鳴らし、開始の通知を基準に口を合わせる。
  """
  alias HelloKioskBrain.{Audio, Draw, PapapaDemo}

  @w 854
  @bg 0x101C30
  @wav "/tmp/hkb_talk.wav"
  @win_ms 60
  @again_ms 8_000

  def init(now), do: %{t0: nil, env: [], next: now + 600, text: "", sub: "", mouth: :closed, drawn: nil, playing: false}

  def full(s), do: [Draw.clear(@bg), Draw.text(div(@w, 2), 14, :tc, :jp20, 0x90A8C0, "おしゃべり時計"), body(s)]

  def frame(s, now) do
    s = if not s.playing and now >= s.next, do: speak(s, now), else: s
    mouth = mouth_at(s, now)
    s = %{s | mouth: mouth}
    key = {mouth, s.text}

    if key != s.drawn, do: {body(s), %{s | drawn: key}, 30}, else: {[], s, 30}
  end

  def event({:audio_file_started, ms}, s), do: %{s | t0: ms}
  def event({:audio_file_done, _}, s), do: %{s | playing: false, t0: nil, next: System.monotonic_time(:millisecond) + @again_ms}
  def event(_, s), do: s

  def stop(_s), do: Audio.stop_file()

  defp speak(s, now) do
    jst = DateTime.add(DateTime.utc_now(), 9 * 3600, :second)
    {h, m} = {jst.hour, jst.minute}
    text = "ただいま #{h}時#{String.pad_leading("#{m}", 2, "0")}分 です"
    sub = "#{jst.year}年#{jst.month}月#{jst.day}日(#{Enum.at(~w(月 火 水 木 金 土 日), Date.day_of_week(jst) - 1)})"
    items = [{:silence, 200}, "time/h#{pad(h)}", "time/m#{pad(m)}"]

    with :ok <- Audio.render_seq(items, @wav),
         :ok <- Audio.play_file(@wav, self()) do
      %{s | env: envelope(@wav), text: text, sub: sub, playing: true, t0: nil}
    else
      _ -> %{s | text: text, sub: sub, env: [], next: now + @again_ms}
    end
  catch
    :exit, _ -> %{s | next: now + @again_ms}
  end

  defp mouth_at(%{playing: true, t0: t0, env: env}, now) when is_integer(t0) do
    case Enum.at(env, div(now - t0, @win_ms)) do
      nil -> :closed
      a when a > 5000 -> :open
      a when a > 1500 -> :half
      _ -> :closed
    end
  end

  defp mouth_at(_, _), do: :closed

  # WAV(16bit ステレオ)の振幅を 60 ms ごとに求める(間引いて最大値)
  defp envelope(path) do
    with {:ok, <<_::binary-size(44), data::binary>>} <- File.read(path) do
      step = 48 * @win_ms * 4
      n = div(byte_size(data), step)

      for i <- 0..max(n - 1, 0) do
        for j <- 0..(step - 4)//128, reduce: 0 do
          acc ->
            <<v::little-signed-16>> = binary_part(data, i * step + j, 2)
            max(acc, abs(v))
        end
      end
    else
      _ -> []
    end
  end

  defp body(s) do
    [
      Draw.rect(60, 70, 330, 330, @bg),
      PapapaDemo.character(:gena, 225, 240, s.mouth),
      # 吹き出し
      Draw.rrect(440, 140, 380, 170, 22, 0xF4F6FA),
      Draw.line(440, 220, 400, 245, 0xF4F6FA),
      Draw.line(440, 230, 400, 245, 0xF4F6FA),
      Draw.text(630, 200, :mc, :jp32, 0x1A2638, s.text),
      Draw.text(630, 262, :mc, :jp20, 0x50607A, s.sub),
      Draw.text(div(@w, 2), 452, :mc, :jp16, 0x7088A0, "8 秒ごとに時刻を話します ・ タッチで戻る")
    ]
  end

  defp pad(n), do: String.pad_leading("#{n}", 2, "0")
end
