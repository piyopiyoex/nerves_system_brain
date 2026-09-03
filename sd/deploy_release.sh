#!/bin/bash
# Deploy the hello_kiosk_brain release to the Nerves SD (/srv/erlang).
# First deploy only - subsequent updates go over SSH/SFTP.
# Usage: sudo bash deploy_release.sh
set -eu

DEV=/dev/sdb
MNT=/mnt/brain-root
REL=/home/owner/my_nerves_examples/hello_kiosk_brain/_build/prod/rel/hello_kiosk_brain

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
lsblk -no MODEL "$DEV" | grep -qi transcend || { echo "ABORT: $DEV is not the Transcend microSD"; exit 1; }
lsblk -no LABEL "${DEV}2" | grep -qx rootfs || { echo "ABORT: ${DEV}2 label is not 'rootfs'"; exit 1; }
[ -d "$REL/releases" ] || { echo "ABORT: release not built"; exit 1; }

for m in $(lsblk -no MOUNTPOINTS "${DEV}2" | grep -v '^$'); do umount "$m"; done
mkdir -p "$MNT"
mount "${DEV}2" "$MNT"

rm -rf "$MNT/srv/erlang"
mkdir -p "$MNT/srv/erlang"
cp -a "$REL/." "$MNT/srv/erlang/"
echo "release deployed: $(du -sh "$MNT/srv/erlang" | cut -f1)"

sync
umount "$MNT"
echo "DONE - insert into Brain (cable connected!) and reset."
