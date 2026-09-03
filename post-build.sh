#!/bin/sh
# Board-specific post-build for nerves_system_brain.
# fwup ops are not generated yet (bring-up phase: rootfs is written manually).

set -e

chmod +x $TARGET_DIR/usr/bin/enable_ethernet_gadget
