defmodule HelloKioskBrain.Recorder do
  @moduledoc """
  マイク録音の動作確認用(音声デモ画面の「録音」ボタン)。`arecord`(alsa-lib)で録音する。

  tinyalsa の `tinycap` は本体コーデック(BU26154)で開始閾値の問題から使えない(実機確認)ため alsa-lib の plughw を使う。
  録音は 44.1kHz S16_LE ステレオ固定(本体マイクは左チャンネルのみに入る)。ビープ(タッチ音)の後に開始し、終了後に
  同じ出力先で再生する。進行は `{:rec_state, 文字列}` を呼び出し元へ送る。
  """
  alias HelloKioskBrain.Audio

  @arecord "/usr/bin/arecord"
  @path "/tmp/hkb_rec.wav"
  @secs 5

  @doc "録音デバイスの ALSA 名。録音できるカードが無ければ nil(BT のみ等)。"
  def capture_device do
    case Audio.current_card() do
      %{id: "BrainBU26154"} -> "plughw:CARD=BrainBU26154,DEV=1"
      %{id: id} when is_binary(id) -> if File.exists?("/dev/snd/pcmC#{Audio.current_card().card}D0c"), do: "plughw:CARD=#{id},DEV=0"
      _ -> nil
    end
  end

  def available?, do: File.exists?(@arecord) and capture_device() != nil

  @doc "別プロセスで 録音→再生 を実行し、状態を `parent` へ通知する。"
  def start(parent) do
    spawn(fn -> run(parent) end)
    :ok
  end

  defp run(parent) do
    dev = capture_device()

    cond do
      not File.exists?(@arecord) ->
        send(parent, {:rec_state, "arecord が無い"})

      dev == nil ->
        send(parent, {:rec_state, "録音デバイスなし"})

      true ->
        # マイク感度は保存済み設定を反映してから録る
        HelloKioskBrain.Mixer.apply_saved()
        Audio.touch()
        Process.sleep(900)
        send(parent, {:rec_state, "録音中… #{@secs} 秒"})
        File.rm(@path)

        {out, rc} =
          System.cmd(@arecord, ["-q", "-D", dev, "-f", "S16_LE", "-r", "44100", "-c", "2", "-d", Integer.to_string(@secs), @path],
            stderr_to_stdout: true
          )

        if rc == 0 do
          send(parent, {:rec_state, "再生中…"})
          Audio.play_path(@path)
          Process.sleep(@secs * 1000 + 500)
          send(parent, {:rec_state, "録音 #{@secs} 秒 → 再生 完了"})
        else
          send(parent, {:rec_state, "録音失敗: " <> String.slice(String.trim(out), 0, 40)})
        end
    end
  end
end
