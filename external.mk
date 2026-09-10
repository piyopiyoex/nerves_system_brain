# プロジェクト固有の Buildroot package を読み込む
include $(sort $(wildcard $(NERVES_DEFCONFIG_DIR)/package/*/*.mk))
