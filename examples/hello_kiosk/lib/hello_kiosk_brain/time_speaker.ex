defmodule HelloKioskBrain.TimeSpeaker do
  @moduledoc """
  時報発声 — 現在時刻(JST)を日本語で読み上げる。

  事前生成音声 `priv/audio/time/h00..h23`(「ただいま、N時」)と `m00..m59`(「N分です」)を
  `HelloKioskBrain.Audio.play_seq/1` で **先頭無音 + h + m を 1 ストリームに連結**して鳴らす
  (hello_kiosk_raspad3 の TimeSpeaker を移植。素材も同一)。TTS は実機で動かさない。

  時計が未設定(NTP 未同期、1970 年起点)のときは発声せず `{:error, :clock_unset}` を返す。
  """
  require Logger

  @jst_offset_s 9 * 3600
  # 再生開始の頭切れ防止用の先頭無音(ms)。
  @lead_ms 200

  @doc """
  現在の JST 時刻を読み上げる(直列キュー投入、非ブロッキング)。
  戻り値: `{:ok, {h, m}}` / `{:error, :clock_unset}` / `{:error, reason}`(Audio 側の :unavailable 等)。
  """
  def speak_now do
    case jst_now() do
      %{year: y} when y < 2024 ->
        {:error, :clock_unset}

      %{hour: h, minute: m} ->
        case HelloKioskBrain.Audio.play_seq([{:silence, @lead_ms}, "time/h#{pad(h)}", "time/m#{pad(m)}"]) do
          :ok -> Logger.info("TimeSpeaker: speak #{h}時#{m}分"); {:ok, {h, m}}
          other -> {:error, other}
        end
    end
  end

  @doc "画面表示用「H時M分」。"
  def label({h, m}), do: "#{h}時#{pad(m)}分"

  defp jst_now, do: DateTime.add(DateTime.utc_now(), @jst_offset_s, :second)

  defp pad(n), do: String.pad_leading("#{n}", 2, "0")
end
