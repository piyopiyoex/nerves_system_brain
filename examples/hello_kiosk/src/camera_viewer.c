/*
 * Network-camera monitor helper for SHARP Brain PW-SH6.
 *
 * Pixel path:
 *   JPEG -> scaled RGB decode -> RGB565LE shadow framebuffer -> one full write.
 *
 * Two modes are intentionally supported:
 *
 *   1. CLI mode for Phase-0 benchmarking and offline validation:
 *        camera_viewer [--scale 1|2|4|8] [--output PATH | --dry-run] JPEG
 *
 *   2. Erlang Port mode for the live camera monitor:
 *        camera_viewer --port [--scale 1|2|4|8] [--output PATH | --dry-run]
 *
 * Port mode uses Erlang's {:packet, 4} framing. stdin receives a 4-byte
 * big-endian length followed by one JPEG. stdout returns one framed ACK per
 * input frame. stderr is reserved for diagnostics so it never corrupts the
 * Port protocol.
 */

#include <errno.h>
#include <fcntl.h>
#include <setjmp.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <jpeglib.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define FB_WIDTH 854
#define FB_HEIGHT 480
#define FB_BPP 2
#define FB_STRIDE (FB_WIDTH * FB_BPP)
#define FB_BYTES ((size_t)FB_STRIDE * FB_HEIGHT)
#define DEFAULT_FB "/dev/fb0"
#define DEFAULT_SCALE 4
#define DEFAULT_MAX_JPEG_BYTES (2U * 1024U * 1024U)

#define ACK_OK 0
#define ACK_ERROR 1
#define ERR_PACKET 1
#define ERR_DECODE 2
#define ERR_WRITE 3
#define ERR_MEMORY 4

struct jpeg_error_ctx {
  struct jpeg_error_mgr pub;
  jmp_buf jump;
  char message[JMSG_LENGTH_MAX];
};

struct options {
  const char *jpeg_path;
  const char *output_path;
  int scale;
  int dry_run;
  int port_mode;
  uint32_t max_jpeg_bytes;
};

struct frame_stats {
  unsigned int input_width;
  unsigned int input_height;
  unsigned int output_width;
  unsigned int output_height;
  uint64_t decode_us;
  uint64_t write_us;
};

static void jpeg_error_exit(j_common_ptr cinfo) {
  struct jpeg_error_ctx *err = (struct jpeg_error_ctx *)cinfo->err;
  (*cinfo->err->format_message)(cinfo, err->message);
  longjmp(err->jump, 1);
}

static uint64_t monotonic_us(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
    return 0;
  }
  return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000ULL;
}

static void usage(FILE *stream, const char *program) {
  fprintf(stream,
          "usage:\n"
          "  %s [--scale 1|2|4|8] [--output PATH | --dry-run] JPEG\n"
          "  %s --port [--scale 1|2|4|8] [--output PATH | --dry-run] "
          "[--max-jpeg-bytes N]\n"
          "\n"
          "Decode JPEG, center it in an 854x480 RGB565LE frame, and write the\n"
          "complete frame in one operation. --port enables Erlang {:packet, 4}\n"
          "framing on stdin/stdout.\n"
          "\n"
          "options:\n"
          "  --scale N            JPEG IDCT scale denominator (default: 4)\n"
          "  --output PATH        write RGB565LE frame to PATH instead of %s\n"
          "  --dry-run            decode/compose only; do not write a frame\n"
          "  --port               persistent framed stdin/stdout mode\n"
          "  --max-jpeg-bytes N   Port-mode input limit (default: %u)\n"
          "  --help               show this help\n",
          program, program, DEFAULT_FB, DEFAULT_MAX_JPEG_BYTES);
}

static int parse_scale(const char *value, int *scale) {
  char *end = NULL;
  long parsed = strtol(value, &end, 10);
  if (end == value || *end != '\0') {
    return -1;
  }
  if (parsed != 1 && parsed != 2 && parsed != 4 && parsed != 8) {
    return -1;
  }
  *scale = (int)parsed;
  return 0;
}

static int parse_u32(const char *value, uint32_t *out) {
  char *end = NULL;
  unsigned long parsed = strtoul(value, &end, 10);
  if (end == value || *end != '\0' || parsed == 0 || parsed > UINT32_MAX) {
    return -1;
  }
  *out = (uint32_t)parsed;
  return 0;
}

static int parse_options(int argc, char **argv, struct options *opts) {
  int i;

  opts->jpeg_path = NULL;
  opts->output_path = DEFAULT_FB;
  opts->scale = DEFAULT_SCALE;
  opts->dry_run = 0;
  opts->port_mode = 0;
  opts->max_jpeg_bytes = DEFAULT_MAX_JPEG_BYTES;

  for (i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--help") == 0) {
      usage(stdout, argv[0]);
      return 1;
    }
    if (strcmp(argv[i], "--dry-run") == 0) {
      opts->dry_run = 1;
      continue;
    }
    if (strcmp(argv[i], "--port") == 0) {
      opts->port_mode = 1;
      continue;
    }
    if (strcmp(argv[i], "--scale") == 0) {
      if (++i >= argc || parse_scale(argv[i], &opts->scale) != 0) {
        fprintf(stderr, "camera_viewer: --scale must be 1, 2, 4, or 8\n");
        return -1;
      }
      continue;
    }
    if (strcmp(argv[i], "--output") == 0) {
      if (++i >= argc) {
        fprintf(stderr, "camera_viewer: --output requires a path\n");
        return -1;
      }
      opts->output_path = argv[i];
      continue;
    }
    if (strcmp(argv[i], "--max-jpeg-bytes") == 0) {
      if (++i >= argc || parse_u32(argv[i], &opts->max_jpeg_bytes) != 0) {
        fprintf(stderr, "camera_viewer: --max-jpeg-bytes requires a positive integer\n");
        return -1;
      }
      continue;
    }
    if (argv[i][0] == '-') {
      fprintf(stderr, "camera_viewer: unknown option: %s\n", argv[i]);
      return -1;
    }
    if (opts->jpeg_path != NULL) {
      fprintf(stderr, "camera_viewer: only one JPEG path is allowed\n");
      return -1;
    }
    opts->jpeg_path = argv[i];
  }

  if (opts->port_mode && opts->jpeg_path != NULL) {
    fprintf(stderr, "camera_viewer: JPEG path is not allowed with --port\n");
    return -1;
  }

  if (!opts->port_mode && opts->jpeg_path == NULL) {
    fprintf(stderr, "camera_viewer: JPEG path is required unless --port is used\n");
    return -1;
  }

  return 0;
}

static inline uint16_t rgb888_to_rgb565(uint8_t r, uint8_t g, uint8_t b) {
  return (uint16_t)(((uint16_t)(r & 0xf8) << 8) |
                    ((uint16_t)(g & 0xfc) << 3) |
                    ((uint16_t)b >> 3));
}

static void store_rgb565le(uint8_t *dst, uint16_t pixel) {
  dst[0] = (uint8_t)(pixel & 0xff);
  dst[1] = (uint8_t)(pixel >> 8);
}

static int write_all(int fd, const uint8_t *buf, size_t len) {
  size_t written = 0;

  while (written < len) {
    ssize_t rc = write(fd, buf + written, len - written);
    if (rc < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    if (rc == 0) {
      errno = EIO;
      return -1;
    }
    written += (size_t)rc;
  }

  return 0;
}

static int read_all(int fd, uint8_t *buf, size_t len) {
  size_t read_bytes = 0;

  while (read_bytes < len) {
    ssize_t rc = read(fd, buf + read_bytes, len - read_bytes);
    if (rc < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    if (rc == 0) {
      return read_bytes == 0 ? 1 : -1;
    }
    read_bytes += (size_t)rc;
  }

  return 0;
}

static int write_all_at(int fd, const uint8_t *buf, size_t len) {
  size_t written = 0;

  while (written < len) {
    ssize_t rc = pwrite(fd, buf + written, len - written, (off_t)written);
    if (rc < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    if (rc == 0) {
      errno = EIO;
      return -1;
    }
    written += (size_t)rc;
  }

  return 0;
}

static int write_frame(const char *path, const uint8_t *frame, int allow_create) {
  int flags = O_WRONLY;
  mode_t mode = 0;
  struct stat st;
  int fd;
  int rc;

  if (stat(path, &st) != 0) {
    if (!allow_create) {
      return -1;
    }
    flags |= O_CREAT | O_TRUNC;
    mode = 0644;
  } else if (!S_ISCHR(st.st_mode)) {
    flags |= O_TRUNC;
  }

  fd = open(path, flags, mode);
  if (fd < 0) {
    return -1;
  }

  rc = write_all_at(fd, frame, FB_BYTES);
  if (close(fd) != 0 && rc == 0) {
    rc = -1;
  }

  return rc;
}

static void set_error(char *dst, size_t dst_size, const char *message) {
  if (dst_size == 0) {
    return;
  }
  snprintf(dst, dst_size, "%s", message);
}

static int decode_into_frame(const uint8_t *jpeg, size_t jpeg_len, int scale,
                             uint8_t *frame, struct frame_stats *stats,
                             char *error, size_t error_size) {
  struct jpeg_decompress_struct cinfo;
  struct jpeg_error_ctx jerr;
  JSAMPARRAY row = NULL;
  size_t row_bytes;
  unsigned int x_offset;
  unsigned int y_offset;
  uint64_t started;
  volatile int created = 0;

  memset(&cinfo, 0, sizeof(cinfo));
  memset(&jerr, 0, sizeof(jerr));
  memset(stats, 0, sizeof(*stats));

  cinfo.err = jpeg_std_error(&jerr.pub);
  jerr.pub.error_exit = jpeg_error_exit;

  if (setjmp(jerr.jump)) {
    set_error(error, error_size, jerr.message);
    if (created) {
      jpeg_destroy_decompress(&cinfo);
    }
    return -1;
  }

  jpeg_create_decompress(&cinfo);
  created = 1;
  jpeg_mem_src(&cinfo, jpeg, (unsigned long)jpeg_len);
  jpeg_read_header(&cinfo, TRUE);

  stats->input_width = cinfo.image_width;
  stats->input_height = cinfo.image_height;

  cinfo.scale_num = 1;
  cinfo.scale_denom = (unsigned int)scale;
  cinfo.out_color_space = JCS_RGB;
  jpeg_calc_output_dimensions(&cinfo);

  if (cinfo.output_width > FB_WIDTH || cinfo.output_height > FB_HEIGHT) {
    snprintf(error, error_size,
             "scaled JPEG %ux%u does not fit %dx%d; increase scale denominator",
             cinfo.output_width, cinfo.output_height, FB_WIDTH, FB_HEIGHT);
    jpeg_destroy_decompress(&cinfo);
    return -1;
  }

  memset(frame, 0, FB_BYTES);
  started = monotonic_us();
  jpeg_start_decompress(&cinfo);

  if (cinfo.output_components != 3) {
    snprintf(error, error_size, "expected RGB output, got %d components",
             cinfo.output_components);
    jpeg_destroy_decompress(&cinfo);
    return -1;
  }

  stats->output_width = cinfo.output_width;
  stats->output_height = cinfo.output_height;
  x_offset = (FB_WIDTH - cinfo.output_width) / 2;
  y_offset = (FB_HEIGHT - cinfo.output_height) / 2;
  row_bytes = (size_t)cinfo.output_width * cinfo.output_components;

  row = (*cinfo.mem->alloc_sarray)((j_common_ptr)&cinfo, JPOOL_IMAGE,
                                  (JDIMENSION)row_bytes, 1);

  while (cinfo.output_scanline < cinfo.output_height) {
    JDIMENSION row_index = cinfo.output_scanline;
    uint8_t *dst;
    unsigned int x;

    if (jpeg_read_scanlines(&cinfo, row, 1) != 1) {
      set_error(error, error_size, "short JPEG scanline read");
      jpeg_destroy_decompress(&cinfo);
      return -1;
    }

    dst = frame + ((size_t)(y_offset + row_index) * FB_STRIDE) +
          ((size_t)x_offset * FB_BPP);

    for (x = 0; x < cinfo.output_width; x++) {
      const uint8_t *rgb = &row[0][x * 3];
      store_rgb565le(&dst[x * 2], rgb888_to_rgb565(rgb[0], rgb[1], rgb[2]));
    }
  }

  jpeg_finish_decompress(&cinfo);
  stats->decode_us = monotonic_us() - started;
  jpeg_destroy_decompress(&cinfo);
  return 0;
}

static int render_jpeg(const struct options *opts, const uint8_t *jpeg,
                       size_t jpeg_len, uint8_t *frame,
                       struct frame_stats *stats, char *error,
                       size_t error_size) {
  uint64_t started;

  if (decode_into_frame(jpeg, jpeg_len, opts->scale, frame, stats, error,
                        error_size) != 0) {
    return ERR_DECODE;
  }

  if (!opts->dry_run) {
    started = monotonic_us();
    if (write_frame(opts->output_path, frame,
                    strcmp(opts->output_path, DEFAULT_FB) != 0) != 0) {
      snprintf(error, error_size, "write(%s): %s", opts->output_path,
               strerror(errno));
      return ERR_WRITE;
    }
    stats->write_us = monotonic_us() - started;
  }

  return 0;
}

static int read_file(const char *path, uint8_t **data, size_t *len) {
  FILE *file = NULL;
  long size;
  uint8_t *buf = NULL;

  file = fopen(path, "rb");
  if (file == NULL) {
    return -1;
  }
  if (fseek(file, 0, SEEK_END) != 0 || (size = ftell(file)) < 0 ||
      fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    return -1;
  }
  if ((unsigned long)size > SIZE_MAX) {
    fclose(file);
    errno = EFBIG;
    return -1;
  }

  buf = malloc((size_t)size);
  if (buf == NULL) {
    fclose(file);
    return -1;
  }
  if (size > 0 && fread(buf, 1, (size_t)size, file) != (size_t)size) {
    free(buf);
    fclose(file);
    errno = EIO;
    return -1;
  }

  fclose(file);
  *data = buf;
  *len = (size_t)size;
  return 0;
}

static uint16_t clamp_u16(unsigned int value) {
  return (uint16_t)(value > UINT16_MAX ? UINT16_MAX : value);
}

static uint32_t clamp_u32(uint64_t value) {
  return (uint32_t)(value > UINT32_MAX ? UINT32_MAX : value);
}

static void put_be16(uint8_t *dst, uint16_t value) {
  dst[0] = (uint8_t)(value >> 8);
  dst[1] = (uint8_t)value;
}

static void put_be32(uint8_t *dst, uint32_t value) {
  dst[0] = (uint8_t)(value >> 24);
  dst[1] = (uint8_t)(value >> 16);
  dst[2] = (uint8_t)(value >> 8);
  dst[3] = (uint8_t)value;
}

static int write_packet(const uint8_t *payload, uint32_t payload_len) {
  uint8_t header[4];
  put_be32(header, payload_len);
  if (write_all(STDOUT_FILENO, header, sizeof(header)) != 0) {
    return -1;
  }
  return write_all(STDOUT_FILENO, payload, payload_len);
}

static int write_ok_ack(const struct frame_stats *stats) {
  uint8_t payload[17];
  payload[0] = ACK_OK;
  put_be16(&payload[1], clamp_u16(stats->input_width));
  put_be16(&payload[3], clamp_u16(stats->input_height));
  put_be16(&payload[5], clamp_u16(stats->output_width));
  put_be16(&payload[7], clamp_u16(stats->output_height));
  put_be32(&payload[9], clamp_u32(stats->decode_us));
  put_be32(&payload[13], clamp_u32(stats->write_us));
  return write_packet(payload, sizeof(payload));
}

static int write_error_ack(uint16_t code, const char *message) {
  uint8_t payload[3 + 240];
  size_t message_len = strlen(message);
  if (message_len > sizeof(payload) - 3) {
    message_len = sizeof(payload) - 3;
  }
  payload[0] = ACK_ERROR;
  put_be16(&payload[1], code);
  memcpy(&payload[3], message, message_len);
  return write_packet(payload, (uint32_t)(3 + message_len));
}

static int run_port_mode(const struct options *opts) {
  uint8_t header[4];
  uint8_t *jpeg = NULL;
  size_t jpeg_capacity = 0;
  uint8_t *frame = NULL;
  int result = EXIT_FAILURE;

  frame = calloc(1, FB_BYTES);
  if (frame == NULL) {
    fprintf(stderr, "camera_viewer: unable to allocate %zu-byte framebuffer\n",
            FB_BYTES);
    return EXIT_FAILURE;
  }

  for (;;) {
    uint32_t jpeg_len;
    int read_result;
    struct frame_stats stats;
    char error[256] = {0};
    int render_result;

    read_result = read_all(STDIN_FILENO, header, sizeof(header));
    if (read_result == 1) {
      result = EXIT_SUCCESS;
      break;
    }
    if (read_result != 0) {
      fprintf(stderr, "camera_viewer: failed reading Port packet header\n");
      break;
    }

    jpeg_len = ((uint32_t)header[0] << 24) | ((uint32_t)header[1] << 16) |
               ((uint32_t)header[2] << 8) | (uint32_t)header[3];

    /* A zero-length Port packet requests a graceful shutdown. Since packets are
     * processed serially, all preceding framebuffer writes are complete here. */
    if (jpeg_len == 0) {
      result = EXIT_SUCCESS;
      break;
    }

    if (jpeg_len > opts->max_jpeg_bytes) {
      char message[128];
      snprintf(message, sizeof(message), "invalid JPEG packet size: %u", jpeg_len);
      if (write_error_ack(ERR_PACKET, message) != 0) {
        break;
      }
      /* The unread payload leaves the stream out of sync. Exit so the BEAM can
       * restart us with a clean packet boundary. */
      result = EXIT_FAILURE;
      break;
    }

    if (jpeg_len > jpeg_capacity) {
      uint8_t *new_jpeg = realloc(jpeg, jpeg_len);
      if (new_jpeg == NULL) {
        if (write_error_ack(ERR_MEMORY, "unable to allocate JPEG input buffer") != 0) {
          break;
        }
        /* The payload has not been consumed, so continuing would interpret it
         * as the next packet header. */
        result = EXIT_FAILURE;
        break;
      }
      jpeg = new_jpeg;
      jpeg_capacity = jpeg_len;
    }

    if (read_all(STDIN_FILENO, jpeg, jpeg_len) != 0) {
      fprintf(stderr, "camera_viewer: failed reading Port JPEG payload\n");
      break;
    }

    render_result = render_jpeg(opts, jpeg, jpeg_len, frame, &stats, error,
                                sizeof(error));
    if (render_result == 0) {
      if (write_ok_ack(&stats) != 0) {
        break;
      }
    } else {
      fprintf(stderr, "camera_viewer: %s\n", error);
      if (write_error_ack((uint16_t)render_result, error) != 0) {
        break;
      }
    }
  }

  free(jpeg);
  free(frame);
  return result;
}

static int run_cli_mode(const struct options *opts) {
  uint8_t *jpeg = NULL;
  size_t jpeg_len = 0;
  uint8_t *frame = NULL;
  struct frame_stats stats;
  char error[256] = {0};
  int render_result;
  int rc = EXIT_FAILURE;

  if (read_file(opts->jpeg_path, &jpeg, &jpeg_len) != 0) {
    fprintf(stderr, "camera_viewer: read(%s): %s\n", opts->jpeg_path,
            strerror(errno));
    goto done;
  }

  frame = calloc(1, FB_BYTES);
  if (frame == NULL) {
    fprintf(stderr, "camera_viewer: unable to allocate %zu-byte framebuffer\n",
            FB_BYTES);
    goto done;
  }

  render_result = render_jpeg(opts, jpeg, jpeg_len, frame, &stats, error,
                              sizeof(error));
  if (render_result != 0) {
    fprintf(stderr, "camera_viewer: %s\n", error);
    goto done;
  }

  printf("input=%ux%u output=%ux%u scale=1/%d decode_ms=%.3f "
         "write_ms=%.3f bytes=%zu%s\n",
         stats.input_width, stats.input_height, stats.output_width,
         stats.output_height, opts->scale, stats.decode_us / 1000.0,
         stats.write_us / 1000.0, FB_BYTES,
         opts->dry_run ? " dry_run=true" : "");
  rc = EXIT_SUCCESS;

done:
  free(frame);
  free(jpeg);
  return rc;
}

int main(int argc, char **argv) {
  struct options opts;
  int parsed = parse_options(argc, argv, &opts);

  if (parsed > 0) {
    return EXIT_SUCCESS;
  }
  if (parsed < 0) {
    usage(stderr, argv[0]);
    return 2;
  }

  if (opts.port_mode) {
    return run_port_mode(&opts);
  }
  return run_cli_mode(&opts);
}
