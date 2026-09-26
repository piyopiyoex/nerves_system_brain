# KIOSK 固有の devmem helper をビルドする。
# LovyanGFX/NIF は lovyangfx_elixir dependency が所有する。

PRIV_DIR   = $(MIX_APP_PATH)/priv
DEVMEM_SRC = src/devmem.c
DEVMEM_BIN = $(PRIV_DIR)/bin/devmem

# GNU make defines CC=cc / CXX=g++ by default, so select the target compilers
# explicitly when the legacy release path supplies CROSSCOMPILE. Command-line CC/CXX
# values still take precedence when an explicit override is needed.
ifneq ($(strip $(CROSSCOMPILE)),)
CC := $(CROSSCOMPILE)-gcc
endif

.PHONY: all clean

all: $(DEVMEM_BIN)

$(DEVMEM_BIN): $(DEVMEM_SRC)
	@mkdir -p $(dir $(DEVMEM_BIN))
	$(CC) -Os -static $(DEVMEM_SRC) -o $(DEVMEM_BIN)

clean:
	$(RM) $(DEVMEM_BIN)
