// Phase 0 test: can LovyanGFX build on ARMv5 and draw Japanese to /dev/fb0?
// Draws to an offscreen RGB565 sprite, then writes the whole frame to fb0 with
// pwrite (braindrmfb is slow at small writes; mmap reflection is unsure).
#define LGFX_USE_V1
#define LGFX_LINUX_FB
#include <LovyanGFX.hpp>

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

int main() {
  int w = 854, h = 480, stride = 1708;
  int fd = open("/dev/fb0", O_RDWR);
  if (fd >= 0) {
    struct fb_var_screeninfo var;
    struct fb_fix_screeninfo fix;
    if (ioctl(fd, FBIOGET_VSCREENINFO, &var) == 0) { w = var.xres; h = var.yres; }
    if (ioctl(fd, FBIOGET_FSCREENINFO, &fix) == 0) { stride = fix.line_length; }
  }
  printf("fb geometry: %dx%d stride=%d\n", w, h, stride);

  LGFX_Sprite canvas;
  canvas.setColorDepth(16);
  if (!canvas.createSprite(w, h)) { printf("createSprite failed\n"); return 1; }

  // efont Japanese (U8g2 format), wrapped with lgfx::U8g2font — far smaller
  // than the IPA fonts::lgfxJapanGothic_* set.
  extern const uint8_t lgfx_efont_ja_16[];
  static const lgfx::U8g2font ja16(lgfx_efont_ja_16);

  canvas.fillScreen(canvas.color565(0, 24, 48));
  canvas.setTextColor(canvas.color565(255, 200, 0));
  canvas.setFont(&ja16);
  canvas.setCursor(40, 60);
  canvas.print("日本語テスト: シャープ ブレイン");
  canvas.setTextColor(canvas.color565(255, 255, 255));
  canvas.setCursor(40, 120);
  canvas.print("LovyanGFX on Nerves / PW-SH6");
  canvas.fillRect(40, 180, 200, 80, canvas.color565(80, 220, 120));
  canvas.drawCircle(400, 300, 60, canvas.color565(255, 90, 90));

  // LovyanGFX outputs RGB565 with a byte order opposite to what braindrmfb
  // expects (colors came out wrong), so swap the two bytes of each pixel
  // before writing (matches papapa's "2-byte swap on transfer").
  const uint16_t* src = (const uint16_t*)canvas.getBuffer();
  int npix = w * h;
  uint16_t* swp = (uint16_t*)malloc((size_t)npix * 2);
  for (int i = 0; i < npix; i++) {
    uint16_t v = src[i];
    swp[i] = (uint16_t)((v >> 8) | (v << 8));
  }
  int rowbytes = w * 2;
  if (fd >= 0 && stride == rowbytes) {
    pwrite(fd, swp, (size_t)rowbytes * h, 0);
  } else if (fd >= 0) {
    for (int y = 0; y < h; y++)
      pwrite(fd, (const uint8_t*)swp + (size_t)y * rowbytes, rowbytes, (off_t)y * stride);
  }
  free(swp);
  if (fd >= 0) close(fd);
  printf("done\n");
  return 0;
}
