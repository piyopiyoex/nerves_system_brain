#!/bin/bash
# nerves_system_brain: milestone-1 SD assembly for SHARP Brain PW-SH6
# - p1 (FAT, already written by dd): enable direct SD boot (copy nk/*)
# - p2: fresh ext4 + Nerves rootfs.tar + OTP runtime from staging
# Usage: sudo bash populate_sd.sh
set -eu

DEV=/dev/sdb
O=/home/owner/my_nerves_examples/nerves_system_brain/o
MNT_BOOT=/mnt/brain-boot
MNT_ROOT=/mnt/brain-root

# --- safety checks -----------------------------------------------------------
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
lsblk -no MODEL "$DEV" | grep -qi transcend || { echo "ABORT: $DEV is not the Transcend microSD"; exit 1; }
lsblk -no LABEL "${DEV}1" | grep -qx boot || { echo "ABORT: ${DEV}1 label is not 'boot' (base image not written?)"; exit 1; }
[ -f "$O/images/rootfs.tar" ] || { echo "ABORT: rootfs.tar not found"; exit 1; }
[ -d "$O/staging/usr/lib/erlang" ] || { echo "ABORT: staging erlang not found"; exit 1; }

# --- p1: direct SD boot ------------------------------------------------------
mkdir -p "$MNT_BOOT"
mountpoint -q "$MNT_BOOT" || mount "${DEV}1" "$MNT_BOOT"
if [ -d "$MNT_BOOT/nk" ]; then
    cp -f "$MNT_BOOT"/nk/* "$MNT_BOOT"/
    echo "p1: nk/* copied (direct SD boot enabled)"
fi

# --- p2: Nerves rootfs -------------------------------------------------------
# unmount any automount of p2
for m in $(lsblk -no MOUNTPOINTS "${DEV}2" | grep -v '^$'); do umount "$m"; done
mkfs.ext4 -q -F -L rootfs "${DEV}2"
mkdir -p "$MNT_ROOT"
mount "${DEV}2" "$MNT_ROOT"
tar xf "$O/images/rootfs.tar" -C "$MNT_ROOT"
cp -a "$O/staging/usr/lib/erlang" "$MNT_ROOT/usr/lib/erlang"
echo "p2: rootfs ($(du -sh --exclude=lost+found "$MNT_ROOT" | cut -f1)) written"

# --- finish ------------------------------------------------------------------
sync
umount "$MNT_ROOT" "$MNT_BOOT"
echo "DONE - SD ready. Insert into Brain and reset."
