defmodule HelloKioskBrain.LetterSpeaker do
  @moduledoc """
  キーボード読み上げ A–Z — 押された文字キーを日本語カナ読みで発声する。

  音声は `priv/audio/alpha/A.wav`..`Z.wav`(Open JTalk / Mei ボイスでひらがな入力から合成、
  `scripts/gen_alpha_wav.sh`)。再生は `HelloKioskBrain.Audio.play/1` の直列キュー経由。

  物理キーは evdev のキーコードで届く。既定の対応表は Linux 標準(`input-event-codes.h`:
  KEY_Q=16 … KEY_P=25 / KEY_A=30 … KEY_L=38 / KEY_Z=44 … KEY_M=50)。Brain のキーボードで
  異なる場合は `config :hello_kiosk_brain, letter_keymap: %{code => "A", ...}` で差し替える。
  """

  @default_keymap %{
    16 => "Q", 17 => "W", 18 => "E", 19 => "R", 20 => "T", 21 => "Y", 22 => "U", 23 => "I", 24 => "O", 25 => "P",
    30 => "A", 31 => "S", 32 => "D", 33 => "F", 34 => "G", 35 => "H", 36 => "J", 37 => "K", 38 => "L",
    44 => "Z", 45 => "X", 46 => "C", 47 => "V", 48 => "B", 49 => "N", 50 => "M"
  }

  # 画面表示用の読み(音声素材の合成に使ったひらがなと同一)。
  @yomi %{
    "A" => "えー", "B" => "びー", "C" => "しー", "D" => "でぃー", "E" => "いー", "F" => "えふ", "G" => "じー",
    "H" => "えいち", "I" => "あい", "J" => "じぇー", "K" => "けー", "L" => "える", "M" => "えむ", "N" => "えぬ",
    "O" => "おー", "P" => "ぴー", "Q" => "きゅー", "R" => "あーる", "S" => "えす", "T" => "てぃー", "U" => "ゆー",
    "V" => "ぶい", "W" => "だぶりゅー", "X" => "えっくす", "Y" => "わい", "Z" => "ぜっと"
  }

  @doc "evdev キーコード → 文字(A–Z)。該当しなければ nil。"
  def letter_for(code) when is_integer(code) do
    Map.get(Application.get_env(:hello_kiosk_brain, :letter_keymap, @default_keymap), code)
  end

  @doc "文字(A–Z)を発声。戻り値は Audio.play/1 と同じ(`:ok` / `:unavailable` / `:dropped` / `:error`)。"
  def speak(letter) when is_binary(letter) and byte_size(letter) == 1 do
    HelloKioskBrain.Audio.play("alpha/" <> letter)
  end

  @doc "画面表示用「K(けー)」。"
  def label(letter), do: "#{letter}(#{Map.get(@yomi, letter, "?")})"
end
