#!/usr/bin/env python3
"""「パパパの二重唱」デモの素材を hello_kiosk_papapa(Raspberry Pi 3 版)から作る。

  priv/audio/papapa/duet.wav            ← papapa_duet.wav(伴奏 + 男声 + 女声、48kHz ステレオ 16bit。そのまま)
  priv/audio/papapa/duet_timeline.term  ← papapa_duet_timeline.json(歌パートだけを Erlang の項に)

Brain は JSON ライブラリを持たないので、母艦で項(`:file.consult/1` で読める 1 項)に変換して同梱する。
素材(曲・伴奏 MIDI・Open JTalk の歌声)の利用条件は未整理のため、生成物は .gitignore で追跡しない。
使い方: scripts/gen_papapa_assets.py [--own-accomp] [hello_kiosk_papapa のパス]
"""
import json, shutil, sys, os

args = [a for a in sys.argv[1:] if not a.startswith("--")]
src = args[0] if args else os.path.expanduser("~/my_nerves_examples/hello_kiosk_papapa")
dst = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "priv", "audio", "papapa")
os.makedirs(dst, exist_ok=True)

# 既定は従来の伴奏(papapa_duet。flutetunes の MIDI 由来。ユーザーが音楽的にこちらを採用、2026-11-12)。
# `--own-accomp` を付けると、自作の伴奏版(tools/gen_accompaniment.py + mix_song.py --out-prefix papapa_duet_orig)を使う。
# 権利上、従来の伴奏は自機限定(docs/20261112_デモ素材の権利整理_パパパの二重唱.md)。
own = "--own-accomp" in sys.argv
prefix = "papapa_duet_orig" if own else "papapa_duet"
print("using", prefix)
shutil.copyfile(os.path.join(src, f"priv/audio/{prefix}.wav"), os.path.join(dst, "duet.wav"))

t = json.load(open(os.path.join(src, f"priv/audio/{prefix}_timeline.json")))
vocal = sorted((e for e in t["events"] if e["part"] in ("male", "female")), key=lambda e: e["t_ms"])
ev = ",\n  ".join(
    "#{t => %d, dur => %d, part => %s, vocab => <<\"%s\">>}" % (e["t_ms"], e["dur_ms"], e["part"], e["vocab"])
    for e in vocal
)
with open(os.path.join(dst, "duet_timeline.term"), "w") as f:
    f.write("#{duration_ms => %d, events => [\n  %s\n]}.\n" % (t["duration_ms"], ev))
print("wrote", dst, len(vocal), "vocal events,", t["duration_ms"], "ms")
