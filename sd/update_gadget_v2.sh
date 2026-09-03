#!/bin/bash
# Deploy gadget script v2 + lns helper to the Nerves SD (p2).
# Usage: sudo bash update_gadget_v2.sh
set -eu

DEV=/dev/sdb
MNT=/mnt/brain-root
SRC=/home/owner/my_nerves_examples/nerves_system_brain/rootfs_overlay

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
lsblk -no MODEL "$DEV" | grep -qi transcend || { echo "ABORT: $DEV is not the Transcend microSD"; exit 1; }
lsblk -no LABEL "${DEV}2" | grep -qx rootfs || { echo "ABORT: ${DEV}2 label is not 'rootfs'"; exit 1; }

for m in $(lsblk -no MOUNTPOINTS "${DEV}2" | grep -v '^$'); do umount "$m"; done
mkdir -p "$MNT"
mount "${DEV}2" "$MNT"

install -m 755 "$SRC/usr/bin/lns" "$MNT/usr/bin/lns"
install -m 755 "$SRC/usr/bin/enable_ethernet_gadget" "$MNT/usr/bin/enable_ethernet_gadget"
echo brain > "$MNT/etc/hostname"

sync
umount "$MNT"
echo "DONE - reinsert into Brain and reset."
