#!/bin/bash
# Generate priv/audio/alpha/A.wav..Z.wav (48kHz/16bit/mono) with Open JTalk (Mei voice),
# same voice family as the time clips (raspad3 h/m) and startup.wav. Hiragana input
# (kanji/katakana read unnaturally). Requires ~/nerves_examples/open_jtalk_elixir.
set -eu
OUT="$(cd "$(dirname "$0")/.." && pwd)/priv/audio/alpha"
OJ=/home/owner/nerves_examples/open_jtalk_elixir
mkdir -p "$OUT"
cd "$OJ"; unset MIX_TARGET; export OPENJTALK_FULL_STATIC=0
mise exec -- mix run -e '
out = System.get_env("ALPHA_OUT")
words = [{"A","えー"},{"B","びー"},{"C","しー"},{"D","でぃー"},{"E","いー"},{"F","えふ"},{"G","じー"},
         {"H","えいち"},{"I","あい"},{"J","じぇー"},{"K","けー"},{"L","える"},{"M","えむ"},{"N","えぬ"},
         {"O","おー"},{"P","ぴー"},{"Q","きゅー"},{"R","あーる"},{"S","えす"},{"T","てぃー"},{"U","ゆー"},
         {"V","ぶい"},{"W","だぶりゅー"},{"X","えっくす"},{"Y","わい"},{"Z","ぜっと"}]
for {l, yomi} <- words do
  path = Path.join(out, l <> ".wav")
  :ok = OpenJTalk.to_wav_file(yomi, out: path) |> case do {:ok, _} -> :ok; :ok -> :ok; other -> IO.inspect(other, label: l); :ok end
  IO.puts("#{l} <- #{yomi}")
end' 2>&1 | grep -vE '^(Compiling|Generated|mkdir)'
