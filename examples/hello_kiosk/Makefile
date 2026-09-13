# KIOSK フレームワークの描画 NIF をビルドする。
# LovyanGFX を Linux フレームバッファ(/dev/fb0)モードでビルドし、Elixir から
# 描画コマンド列を受け取って描画する薄ラッパ NIF を生成する。
#
# elixir_make 駆動。Nerves が CC/CXX(クロスツールチェイン)と
# ERTS_INCLUDE_DIR / ERL_EI_INCLUDE_DIR(erl_nif ヘッダ)を与える。

PRIV_DIR  = $(MIX_APP_PATH)/priv
NIF_SO    = $(PRIV_DIR)/kiosk_nif.so

LGFX_REPO = https://github.com/lovyan03/LovyanGFX.git
LGFX_DIR  = c_src/LovyanGFX
LGFX_SRC  = $(LGFX_DIR)/src

ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~ts/erts-~ts/include/", [code:root_dir(), erlang:system_info(version)]), halt().')

# GNU make defines CXX=g++ by default, so ?= would silently select the host
# compiler even when CROSSCOMPILE is supplied. A command-line CXX still takes
# precedence over this assignment when an explicit override is needed.
ifneq ($(strip $(CROSSCOMPILE)),)
CXX := $(CROSSCOMPILE)-g++
endif

# LovyanGFX Linux フレームバッファ用ビルドセット（efont/IPA 日本語フォント含む）
LGFX_SOURCES = \
	$(wildcard $(LGFX_SRC)/lgfx/v1/*.cpp) \
	$(wildcard $(LGFX_SRC)/lgfx/v1/misc/*.cpp) \
	$(LGFX_SRC)/lgfx/v1/panel/Panel_Device.cpp \
	$(wildcard $(LGFX_SRC)/lgfx/v1/platforms/framebuffer/*.cpp) \
	$(wildcard $(LGFX_SRC)/lgfx/Fonts/efont/*.c) \
	$(wildcard $(LGFX_SRC)/lgfx/Fonts/IPA/*.c) \
	$(wildcard $(LGFX_SRC)/lgfx/Fonts/lvgl/*.c) \
	$(wildcard $(LGFX_SRC)/lgfx/utility/*.c) \
	$(wildcard $(LGFX_SRC)/lgfx/v1/lv_font/*.c)

NIF_SOURCES = c_src/kiosk_nif.cpp

CPPFLAGS = -DLGFX_USE_V1 -DLGFX_LINUX_FB \
	-I$(LGFX_SRC) -I$(ERTS_INCLUDE_DIR)
# -ffunction-sections/-fdata-sections + --gc-sections で未使用シンボルを除去する。
# LovyanGFX の Fonts wildcard は efont(ja/cn/kr/tw ~93MB) を含むが NIF は IPA
# lgfxJapanGothic しか使わない。gc-sections でリンク時に未使用フォントを落とし、
# -s で debug_info を除去すると .so が 44MB → ~2.7MB になり、実機(128MB/ARMv5)の
# 起動時 dlopen とメモリ圧迫が大幅に軽減される(日本語描画に必要な IPA は保持される)。
CXXFLAGS += -std=c++17 -O2 -fPIC -fvisibility=hidden -Wno-deprecated-declarations \
	-ffunction-sections -fdata-sections
LDFLAGS  += -shared -Wl,--gc-sections -s
LDLIBS   += -lpthread

.PHONY: all clean

all: $(NIF_SO)

$(LGFX_DIR):
	@echo "Fetching LovyanGFX..."
	git clone --depth 1 $(LGFX_REPO) $(LGFX_DIR)

$(NIF_SO): $(LGFX_DIR) $(NIF_SOURCES) c_src/kiosk_draw.hpp c_src/icons.cpp
	@mkdir -p $(PRIV_DIR)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(NIF_SOURCES) $(LGFX_SOURCES) \
		$(LDFLAGS) $(LDLIBS) -o $(NIF_SO)

clean:
	$(RM) $(NIF_SO)
