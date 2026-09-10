################################################################################
#
# lns
#
################################################################################

LNS_VERSION = 0.1.0
LNS_SOURCE =

define LNS_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -static \
		$(NERVES_DEFCONFIG_DIR)/package/lns/lns.c \
		-o $(@D)/lns
endef

define LNS_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 755 $(@D)/lns $(TARGET_DIR)/usr/bin/lns
endef

$(eval $(generic-package))
