// KIOSK フレームワーク 共有描画インタプリタ
//
// Elixir(Nerves) 側が生成する「描画コマンド列（テキストプロトコル）」を解釈し、
// LovyanGFX の描画 API を呼び出して任意のキャンバス（LGFX_Sprite / パネル）へ
// 描画する。NIF（実機: /dev/fb0）とホスト検証（PNG 出力）の双方がこの 1 つの
// パーサ/実行器を共有するため、画面定義は Elixir に一元化できる。
//
// プロトコル: 1 行 1 コマンド。フィールドはタブ区切り。色は RGB888 の 16 進 6 桁。
//   clear\t<color>
//   rect\t<x>\t<y>\t<w>\t<h>\t<color>            塗り矩形
//   frame\t<x>\t<y>\t<w>\t<h>\t<color>           枠線矩形
//   rrect\t<x>\t<y>\t<w>\t<h>\t<r>\t<color>      塗り角丸矩形
//   rframe\t<x>\t<y>\t<w>\t<h>\t<r>\t<color>     枠線角丸矩形
//   line\t<x1>\t<y1>\t<x2>\t<y2>\t<color>
//   circle\t<x>\t<y>\t<r>\t<color>               枠線円
//   fcircle\t<x>\t<y>\t<r>\t<color>              塗り円
//   text\t<x>\t<y>\t<datum>\t<font>\t<color>\t<string>
//     datum: tl tc tr ml mc mr bl bc br
//     font : jp8 jp12 jp16 jp20 jp24 jp28 jp32 jp36 jp40 (efont/IPA 日本語ゴシック)
#pragma once

#include <LovyanGFX.hpp>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>

namespace kiosk {

inline const lgfx::IFont* font_by_name(const std::string& n) {
  if (n == "jp8")  return &fonts::lgfxJapanGothic_8;
  if (n == "jp12") return &fonts::lgfxJapanGothic_12;
  if (n == "jp16") return &fonts::lgfxJapanGothic_16;
  if (n == "jp20") return &fonts::lgfxJapanGothic_20;
  if (n == "jp24") return &fonts::lgfxJapanGothic_24;
  if (n == "jp28") return &fonts::lgfxJapanGothic_28;
  if (n == "jp32") return &fonts::lgfxJapanGothic_32;
  if (n == "jp36") return &fonts::lgfxJapanGothic_36;
  if (n == "jp40") return &fonts::lgfxJapanGothic_40;
  return &fonts::lgfxJapanGothic_20;
}

inline lgfx::textdatum_t datum_by_name(const std::string& d) {
  using lgfx::textdatum_t;
  if (d == "tc") return textdatum_t::top_center;
  if (d == "tr") return textdatum_t::top_right;
  if (d == "ml") return textdatum_t::middle_left;
  if (d == "mc") return textdatum_t::middle_center;
  if (d == "mr") return textdatum_t::middle_right;
  if (d == "bl") return textdatum_t::bottom_left;
  if (d == "bc") return textdatum_t::bottom_center;
  if (d == "br") return textdatum_t::bottom_right;
  return textdatum_t::top_left;  // "tl" / default
}

// タブ区切りでフィールド分割。text コマンドの文字列はタブを含まない前提で
// 末尾フィールドにそのまま入る（空白は許容）。
inline void split_tab(const std::string& line, std::vector<std::string>& out) {
  out.clear();
  size_t p = 0;
  for (;;) {
    size_t t = line.find('\t', p);
    if (t == std::string::npos) { out.push_back(line.substr(p)); break; }
    out.push_back(line.substr(p, t - p));
    p = t + 1;
  }
}

// 描画コマンド列を実行する。gfx は LGFX_Sprite でもパネルでも可。
inline void execute(lgfx::LGFXBase& gfx, const char* buf, size_t len) {
  std::vector<std::string> f;
  size_t i = 0;
  while (i < len) {
    size_t j = i;
    while (j < len && buf[j] != '\n') ++j;
    std::string line(buf + i, j - i);
    i = j + 1;
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty()) continue;

    split_tab(line, f);
    const std::string& op = f[0];

    auto I = [&](size_t k) { return (int)strtol(f[k].c_str(), nullptr, 10); };
    auto C = [&](size_t k) {
      uint32_t v = (uint32_t)strtoul(f[k].c_str(), nullptr, 16);
      return gfx.color888((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff);
    };

    if      (op == "clear"   && f.size() >= 2) gfx.fillScreen(C(1));
    else if (op == "rect"    && f.size() >= 6) gfx.fillRect(I(1), I(2), I(3), I(4), C(5));
    else if (op == "frame"   && f.size() >= 6) gfx.drawRect(I(1), I(2), I(3), I(4), C(5));
    else if (op == "rrect"   && f.size() >= 7) gfx.fillRoundRect(I(1), I(2), I(3), I(4), I(5), C(6));
    else if (op == "rframe"  && f.size() >= 7) gfx.drawRoundRect(I(1), I(2), I(3), I(4), I(5), C(6));
    else if (op == "line"    && f.size() >= 6) gfx.drawLine(I(1), I(2), I(3), I(4), C(5));
    else if (op == "circle"  && f.size() >= 5) gfx.drawCircle(I(1), I(2), I(3), C(4));
    else if (op == "fcircle" && f.size() >= 5) gfx.fillCircle(I(1), I(2), I(3), C(4));
    else if (op == "text"    && f.size() >= 7) {
      gfx.setFont(font_by_name(f[4]));
      gfx.setTextColor(C(5));
      gfx.setTextDatum(datum_by_name(f[3]));
      gfx.drawString(f[6].c_str(), I(1), I(2));
    }
  }
}

}  // namespace kiosk
