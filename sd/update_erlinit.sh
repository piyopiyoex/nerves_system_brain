#!/bin/bash
# Add automatic USB-NCM gadget bring-up to the Nerves SD (milestone-1).
# Usage: sudo bash update_erlinit.sh
set -eu

DEV=/dev/sdb
MNT=/mnt/brain-root

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
lsblk -no MODEL "$DEV" | grep -qi transcend || { echo "ABORT: $DEV is not the Transcend microSD"; exit 1; }
lsblk -no LABEL "${DEV}2" | grep -qx rootfs || { echo "ABORT: ${DEV}2 label is not 'rootfs'"; exit 1; }

for m in $(lsblk -no MOUNTPOINTS "${DEV}2" | grep -v '^$'); do umount "$m"; done
mkdir -p "$MNT"
mount "${DEV}2" "$MNT"

CFG="$MNT/etc/erlinit.config"
grep -q 'pre-run-exec' "$CFG" || cat >> "$CFG" <<'EOF'

# Bring up the USB NCM gadget before starting Erlang (no typing needed)
--pre-run-exec /usr/bin/enable_ethernet_gadget
EOF
echo "--- erlinit.config now: ---"
cat "$CFG"

sync
umount "$MNT"
echo "DONE - reinsert into Brain and reset."
