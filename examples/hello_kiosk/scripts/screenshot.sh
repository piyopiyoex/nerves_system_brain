#!/bin/bash
# Capture the Brain's LCD (framebuffer) as PNG via SSH.
# Resolution-agnostic: geometry (width/height/stride) is read from the device.
# Usage: scripts/screenshot.sh [out.png]   (default: ./brain_screen.png)
set -eu
OUT="${1:-brain_screen.png}"
HOST=user@10.42.0.2
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

GEO=$(ssh $SSH_OPTS $HOST 'g="/sys/class/graphics/fb0/"; String.replace(String.trim(File.read!(g<>"virtual_size")),","," ")<>" "<>String.trim(File.read!(g<>"stride"))' 2>/dev/null | tr -d '"')
read -r W H STRIDE <<< "$GEO"
SIZE=$((STRIDE * H))

ssh $SSH_OPTS $HOST "{:ok,fd}=:file.open(~c\"/dev/fb0\",[:read,:raw,:binary]); {:ok,d}=:file.read(fd,$SIZE); :file.close(fd); File.write!(\"/root/fb.bin\",d); byte_size(d)" >/dev/null 2>&1
TMP=$(mktemp)
echo "get /root/fb.bin $TMP" | sftp -q $SSH_OPTS $HOST >/dev/null 2>&1

python3 - "$TMP" "$OUT" "$W" "$H" "$STRIDE" <<'EOF'
import sys
from PIL import Image
path, out, W, H, STRIDE = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
data = open(path, "rb").read()
img = Image.new("RGB", (W, H))
px = img.load()
for y in range(H):
    base = y * STRIDE
    for x in range(W):
        v = data[base + 2*x] | (data[base + 2*x + 1] << 8)
        px[x, y] = ((v >> 11 & 0x1F) << 3, (v >> 5 & 0x3F) << 2, (v & 0x1F) << 3)
img.save(out)
EOF
rm -f "$TMP"
echo "saved: $OUT (${W}x${H}, stride $STRIDE)"
