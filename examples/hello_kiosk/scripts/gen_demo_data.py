#!/usr/bin/env python3
"""デモ用データ(世界地図の陸地マスク、星表と星座線)を作る。母艦で 1 回実行し、priv/demo/*.term を同梱する。

  priv/demo/world.term  … 陸地マスク(210×105 セル、1 セル 4px。行ごとの陸地の区間 {開始, 長さ})
                           出典: Natural Earth 1:110m land(パブリックドメイン)
  priv/demo/stars.term  … 4 等級までの恒星 {赤経°, 赤緯°, 等級} と星座線(赤経・赤緯の折れ線)
                           出典: d3-celestial の stars.6.json / constellations.lines.json(BSD 3-Clause, © Olaf Frohn)

Brain に JSON ライブラリが無いので、Erlang の項(`:file.consult/1` で読める 1 項)にする。
使い方: scripts/gen_demo_data.py [データの置き場(既定 /tmp/claude-1000/demo_data)]
"""
import json, os, sys, urllib.request
import numpy as np

src = sys.argv[1] if len(sys.argv) > 1 else "/tmp/claude-1000/demo_data"
dst = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "priv", "demo")
os.makedirs(dst, exist_ok=True)
URLS = {
    "ne_110m_land.geojson": "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_land.geojson",
    "stars.6.json": "https://raw.githubusercontent.com/ofrohn/d3-celestial/master/data/stars.6.json",
    "constellations.lines.json": "https://raw.githubusercontent.com/ofrohn/d3-celestial/master/data/constellations.lines.json",
}
os.makedirs(src, exist_ok=True)
for f, u in URLS.items():
    p = os.path.join(src, f)
    if not os.path.exists(p):
        urllib.request.urlretrieve(u, p)

# --- 世界地図: 陸地マスク -------------------------------------------------------
W, H = 210, 105
lon = -180 + (np.arange(W) + 0.5) * 360 / W
lat = 90 - (np.arange(H) + 0.5) * 180 / H
LON, LAT = np.meshgrid(lon, lat)
inside = np.zeros((H, W), dtype=bool)
land = json.load(open(os.path.join(src, "ne_110m_land.geojson")))
for feat in land["features"]:
    g = feat["geometry"]
    polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
    for poly in polys:
        for ring in poly:  # 外周と穴を偶奇規則でまとめて扱う
            r = np.array(ring)
            x1, y1 = r[:-1, 0], r[:-1, 1]
            x2, y2 = r[1:, 0], r[1:, 1]
            for a, b, c, d in zip(x1, y1, x2, y2):
                cond = ((b > LAT) != (d > LAT))
                xi = a + (LAT - b) * (c - a) / ((d - b) if d != b else 1e-12)
                inside ^= cond & (LON < xi)
rows = []
for j in range(H):
    runs, i = [], 0
    while i < W:
        if inside[j, i]:
            k = i
            while k < W and inside[j, k]:
                k += 1
            runs.append("{%d, %d}" % (i, k - i))
            i = k
        else:
            i += 1
    rows.append("[" + ", ".join(runs) + "]")
with open(os.path.join(dst, "world.term"), "w") as f:
    f.write("#{w => %d, h => %d, rows => [\n  %s\n]}.\n" % (W, H, ",\n  ".join(rows)))

# --- 星表と星座線 ---------------------------------------------------------------
stars = json.load(open(os.path.join(src, "stars.6.json")))["features"]
st = [(s["geometry"]["coordinates"][0] % 360, s["geometry"]["coordinates"][1], s["properties"]["mag"]) for s in stars if s["properties"]["mag"] <= 4.0]
lines = []
for c in json.load(open(os.path.join(src, "constellations.lines.json")))["features"]:
    for line in c["geometry"]["coordinates"]:
        lines.append("[" + ", ".join("{%.2f, %.2f}" % (p[0] % 360, p[1]) for p in line) + "]")
with open(os.path.join(dst, "stars.term"), "w") as f:
    f.write("#{stars => [\n  %s\n], lines => [\n  %s\n]}.\n" % (",\n  ".join("{%.2f, %.2f, %.2f}" % s for s in st), ",\n  ".join(lines)))
print("world: land cells", int(inside.sum()), "of", W * H, "| stars:", len(st), "| constellation polylines:", len(lines))
