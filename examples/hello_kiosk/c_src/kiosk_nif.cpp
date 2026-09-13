// KIOSK フレームワーク 描画 NIF（LovyanGFX 薄ラッパ）
//
// API:
//   init_display/0          フレームバッファ(/dev/fb0)とオフスクリーンキャンバスを初期化
//   render/1                描画コマンド列(テキストプロトコル)を 1 フレームとして描画
//   start_moving_icons/0    LovyanGFX "MovingIcons" デモを背景スレッドで開始
//   stop_moving_icons/0     MovingIcons デモを停止
//
// 描画は常にオフスクリーンキャンバス(LGFX_Sprite)へ行い、blit_to_fb() で
// /dev/fb0(mmap)へ 2 バイトスワップしながら転送する。LovyanGFX は RGB565 を
// 内部でビッグエンディアン格納するが、Linux フレームバッファ(16bpp)は CPU
// ネイティブ(リトルエンディアン)を期待するため、転送時にスワップして整合させる。

#define LGFX_USE_V1
#define LGFX_LINUX_FB
#include <LovyanGFX.hpp>

#include "kiosk_draw.hpp"
#include "icons.cpp"  // info[] / alert[] / closeX[] (32x32 RGB565)

#include <erl_nif.h>
#include <atomic>
#include <thread>
#include <mutex>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

#define SCREEN_X 854
#define SCREEN_Y 480
#define DEVICE_NAME "/dev/fb0"

static LGFX_Sprite canvas;  // オフスクリーン(800x480, RGB565)
static std::mutex g_mtx;    // canvas / fb への排他
static bool g_inited = false;

// フレームバッファ mmap
static int g_fb_fd = -1;
static uint16_t* g_fb = nullptr;
static size_t g_fb_len = 0;
static int g_fb_stride_px = SCREEN_X;

static ERL_NIF_TERM mk_atom(ErlNifEnv* env, const char* s) {
  ERL_NIF_TERM a;
  if (enif_make_existing_atom(env, s, &a, ERL_NIF_LATIN1)) return a;
  return enif_make_atom(env, s);
}

static bool ensure_init() {
  if (g_inited) return true;

  g_fb_fd = open(DEVICE_NAME, O_RDWR);
  if (g_fb_fd < 0) return false;

  struct fb_fix_screeninfo fix;
  struct fb_var_screeninfo var;
  if (ioctl(g_fb_fd, FBIOGET_FSCREENINFO, &fix) < 0) return false;
  if (ioctl(g_fb_fd, FBIOGET_VSCREENINFO, &var) < 0) return false;

  g_fb_stride_px = fix.line_length / 2;
  g_fb_len = fix.line_length * var.yres_virtual;
  g_fb = (uint16_t*)mmap(nullptr, g_fb_len, PROT_READ | PROT_WRITE, MAP_SHARED, g_fb_fd, 0);
  if (g_fb == MAP_FAILED) { g_fb = nullptr; return false; }

  canvas.setColorDepth(16);
  if (!canvas.createSprite(SCREEN_X, SCREEN_Y)) return false;

  g_inited = true;
  return true;
}

// canvas(内部=BE RGB565) -> fb(LE RGB565) を 2 バイトスワップ転送。
static void blit_to_fb() {
  const uint16_t* src = (const uint16_t*)canvas.getBuffer();
  for (int y = 0; y < SCREEN_Y; ++y) {
    uint16_t* d = g_fb + (size_t)y * g_fb_stride_px;
    const uint16_t* s = src + (size_t)y * SCREEN_X;
    for (int x = 0; x < SCREEN_X; ++x) {
      uint16_t v = s[x];
      d[x] = (uint16_t)((v >> 8) | (v << 8));
    }
  }
}

// ---- MovingIcons デモ -------------------------------------------------------

static constexpr unsigned short ICON_W = 32, ICON_H = 32;
static constexpr size_t OBJ_COUNT = 50;

struct obj_info_t {
  int_fast16_t x, y, dx, dy;
  int_fast8_t img;
  float r, z, dr, dz;
  void move() {
    r += dr;
    x += dx;
    if (x < 0) { x = 0; if (dx < 0) dx = -dx; }
    else if (x >= SCREEN_X) { x = SCREEN_X - 1; if (dx > 0) dx = -dx; }
    y += dy;
    if (y < 0) { y = 0; if (dy < 0) dy = -dy; }
    else if (y >= SCREEN_Y) { y = SCREEN_Y - 1; if (dy > 0) dy = -dy; }
    z += dz;
    if (z < .5f) { z = .5f; if (dz < .0f) dz = -dz; }
    else if (z >= 2.0f) { z = 2.0f; if (dz > .0f) dz = -dz; }
  }
};

static obj_info_t g_objs[OBJ_COUNT];
static LGFX_Sprite g_icons[3];
static bool g_icons_ready = false;
static std::atomic<bool> g_moving{false};
static std::thread g_anim;
static size_t g_fps = 0;

static double mono_seconds() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void moving_setup() {
  if (!g_icons_ready) {
    g_icons[0].createSprite(ICON_W, ICON_H);
    g_icons[1].createSprite(ICON_W, ICON_H);
    g_icons[2].createSprite(ICON_W, ICON_H);
    // アイコンは標準 RGB565 データ。blit でスワップする本パイプラインに合わせ、
    // 取り込み時にスワップして canvas 内部形式(BE)へ揃える。
    g_icons[0].setSwapBytes(true);
    g_icons[1].setSwapBytes(true);
    g_icons[2].setSwapBytes(true);
    g_icons[0].pushImage(0, 0, ICON_W, ICON_H, info);
    g_icons[1].pushImage(0, 0, ICON_W, ICON_H, alert);
    g_icons[2].pushImage(0, 0, ICON_W, ICON_H, closeX);
    g_icons_ready = true;
  }

  for (size_t i = 0; i < OBJ_COUNT; ++i) {
    obj_info_t* a = &g_objs[i];
    a->img = i % 3;
    a->x = rand() % SCREEN_X;
    a->y = rand() % SCREEN_Y;
    a->dx = ((rand() & 3) + 1) * (i & 1 ? 1 : -1);
    a->dy = ((rand() & 3) + 1) * (i & 2 ? 1 : -1);
    a->dr = ((rand() & 3) + 1) * (i & 2 ? 1 : -1);
    a->r = 0;
    a->z = (float)((rand() % 10) + 10) / 10;
    a->dz = (float)((rand() % 10) + 1) / 100;
  }
}

static void moving_loop() {
  double t0 = mono_seconds();
  size_t frames = 0;

  while (g_moving.load()) {
    {
      std::lock_guard<std::mutex> lk(g_mtx);
      canvas.fillScreen(canvas.color888(0, 0, 0));
      for (size_t i = 0; i < OBJ_COUNT; ++i) {
        obj_info_t* a = &g_objs[i];
        a->move();  // 位置・回転・拡大率を更新(これが無いと静止画になる)
        g_icons[a->img].pushRotateZoom(&canvas, a->x, a->y, a->r, a->z, a->z, 0);
      }

      // アイコン数・FPS(左上)
      char buf[64];
      snprintf(buf, sizeof(buf), "obj:%d  fps:%d", (int)OBJ_COUNT, (int)g_fps);
      canvas.setFont(&fonts::Font4);
      canvas.setTextColor(canvas.color888(255, 255, 0));
      canvas.setTextDatum(textdatum_t::top_left);
      canvas.drawString(buf, 6, 2);

      // 見出し・操作案内(日本語)
      canvas.setFont(&fonts::lgfxJapanGothic_24);
      canvas.setTextColor(canvas.color888(255, 255, 255));
      canvas.drawString("MovingIcons 実行中", 6, 34);
      canvas.setTextDatum(textdatum_t::top_right);
      canvas.drawString("タッチでホームへ戻る", SCREEN_X - 6, 2);
      canvas.setTextDatum(textdatum_t::top_left);

      blit_to_fb();
    }

    if (++frames >= 8) {  // 定期的に FPS 更新
      double now = mono_seconds();
      double dt = now - t0;
      if (dt > 0.0) g_fps = (size_t)(frames / dt + 0.5);
      frames = 0;
      t0 = now;
    }
    usleep(16000);  // ~60fps 上限
  }
}

// ---- NIF entry points -------------------------------------------------------

static ERL_NIF_TERM nif_init_display(ErlNifEnv* env, int, const ERL_NIF_TERM[]) {
  std::lock_guard<std::mutex> lk(g_mtx);
  return ensure_init() ? mk_atom(env, "ok") : mk_atom(env, "error");
}

static ERL_NIF_TERM nif_render(ErlNifEnv* env, int, const ERL_NIF_TERM argv[]) {
  ErlNifBinary bin;
  if (!enif_inspect_iolist_as_binary(env, argv[0], &bin)) return enif_make_badarg(env);

  std::lock_guard<std::mutex> lk(g_mtx);
  if (!ensure_init()) return mk_atom(env, "error");

  kiosk::execute(canvas, reinterpret_cast<const char*>(bin.data), bin.size);
  blit_to_fb();
  return mk_atom(env, "ok");
}

static ERL_NIF_TERM nif_start_moving(ErlNifEnv* env, int, const ERL_NIF_TERM[]) {
  std::lock_guard<std::mutex> lk(g_mtx);
  if (!ensure_init()) return mk_atom(env, "error");
  if (g_moving.load()) return mk_atom(env, "already_started");
  moving_setup();
  g_moving.store(true);
  g_anim = std::thread(moving_loop);
  return mk_atom(env, "ok");
}

static ERL_NIF_TERM nif_stop_moving(ErlNifEnv* env, int, const ERL_NIF_TERM[]) {
  if (g_moving.exchange(false)) {
    if (g_anim.joinable()) g_anim.join();
  }
  return mk_atom(env, "ok");
}

static ErlNifFunc nif_funcs[] = {
  {"init_display", 0, nif_init_display, 0},
  {"render", 1, nif_render, ERL_NIF_DIRTY_JOB_CPU_BOUND},
  {"start_moving_icons", 0, nif_start_moving, 0},
  {"stop_moving_icons", 0, nif_stop_moving, 0},
};

ERL_NIF_INIT(Elixir.HelloKioskBrain.Native, nif_funcs, nullptr, nullptr, nullptr, nullptr)
