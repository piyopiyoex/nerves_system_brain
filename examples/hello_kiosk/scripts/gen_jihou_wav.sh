#!/bin/bash
# Generate priv/audio/time/jihou00.wav..jihou23.wav (48kHz/16bit/mono): 「ただいまより、N時をおしらせします」
# Open JTalk (Mei voice) — same voice family as the other clips. Hiragana input (kanji read unnaturally).
# Requires ~/nerves_examples/open_jtalk_elixir.
set -eu
export JIHOU_OUT="$(cd "$(dirname "$0")/.." && pwd)/priv/audio/time"
OJ=/home/owner/nerves_examples/open_jtalk_elixir
mkdir -p "$JIHOU_OUT"
cd "$OJ"; unset MIX_TARGET; export OPENJTALK_FULL_STATIC=0
mise exec -- mix run -e '
out = System.get_env("JIHOU_OUT")
hours = ~w(れい いち に さん よ ご ろく しち はち く じゅう じゅういち じゅうに じゅうさん じゅうよ じゅうご じゅうろく じゅうしち じゅうはち じゅうく にじゅう にじゅういち にじゅうに にじゅうさん)
for {yomi, h} <- Enum.with_index(hours) do
  path = Path.join(out, "jihou" <> String.pad_leading("#{h}", 2, "0") <> ".wav")
  text = "ただいまより、" <> yomi <> "じを、おしらせします。"
  OpenJTalk.to_wav_file(text, out: path) |> case do {:ok, _} -> :ok; :ok -> :ok; other -> IO.inspect(other, label: "#{h}"); :ok end
  IO.puts("#{h} <- #{text}")
end' 2>&1 | grep -vE '^(Compiling|Generated|mkdir)'
