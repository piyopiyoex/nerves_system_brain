# KIOSK-specific native helpers.
# LovyanGFX/NIF is owned by the lovyangfx_elixir dependency.

PRIV_DIR         = $(MIX_APP_PATH)/priv
DEVMEM_SRC       = src/devmem.c
DEVMEM_BIN       = $(PRIV_DIR)/bin/devmem
CAMERA_VIEWER_SRC = src/camera_viewer.c
CAMERA_VIEWER_BIN = $(PRIV_DIR)/bin/camera_viewer

# GNU make defines CC=cc / CXX=g++ by default, so select the target compilers
# explicitly when the legacy release path supplies CROSSCOMPILE. Command-line CC/CXX
# values still take precedence when an explicit override is needed.
ifneq ($(strip $(CROSSCOMPILE)),)
CC := $(CROSSCOMPILE)-gcc
endif

# Nerves places Buildroot headers/libs in the system staging sysroot. The camera
# helper needs libjpeg from there. Keep host builds independent of libjpeg so
# `mix test` remains lightweight; the camera helper is a Brain-target artifact.
CAMERA_VIEWER_CPPFLAGS += -D_POSIX_C_SOURCE=200809L

ifneq ($(strip $(NERVES_SDK_SYSROOT)),)
CAMERA_VIEWER_CPPFLAGS += -I$(NERVES_SDK_SYSROOT)/usr/include
CAMERA_VIEWER_LDFLAGS  += -L$(NERVES_SDK_SYSROOT)/usr/lib \
                          -Wl,-rpath-link,$(NERVES_SDK_SYSROOT)/usr/lib
TARGET_BINS += $(CAMERA_VIEWER_BIN)
endif

.PHONY: all clean

all: $(DEVMEM_BIN) $(TARGET_BINS)

$(DEVMEM_BIN): $(DEVMEM_SRC)
	@mkdir -p $(dir $(DEVMEM_BIN))
	$(CC) -Os -static $(DEVMEM_SRC) -o $(DEVMEM_BIN)

$(CAMERA_VIEWER_BIN): $(CAMERA_VIEWER_SRC)
	@mkdir -p $(dir $(CAMERA_VIEWER_BIN))
	$(CC) $(CPPFLAGS) $(CAMERA_VIEWER_CPPFLAGS) $(CFLAGS) -Os -Wall -Wextra \
		$(CAMERA_VIEWER_SRC) -o $(CAMERA_VIEWER_BIN) \
		$(LDFLAGS) $(CAMERA_VIEWER_LDFLAGS) -ljpeg

clean:
	$(RM) $(DEVMEM_BIN) $(CAMERA_VIEWER_BIN)
