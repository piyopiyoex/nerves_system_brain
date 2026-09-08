#!/usr/bin/env bash
# Runs AFTER board/nerves-common/post-build.sh, whose scrub-target.sh removes
# /etc/wpa_supplicant.conf by design (Nerves expects it provisioned at runtime).
# We reinstate a SECRET-FREE template so enable_wifi has a file to read and the
# WiFi provisioning step is self-documented in the built image.
# Real SSID/PSK are provisioned per-device (image/device level), never committed.
set -e
install -m 0600 "$NERVES_DEFCONFIG_DIR/wpa_supplicant.conf.template" \
                "$TARGET_DIR/etc/wpa_supplicant.conf"
