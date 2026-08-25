#!/usr/bin/env bash
# Stage 40 - assemble the flashable .img.
#
# Produces a two-partition MBR image: a FAT32 firmware partition the Raspberry
# Pi bootloader reads, and an ext4 root. Root is deliberately smaller than most
# cards so the image stays quick to flash; it grows itself on first boot.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../config/build.env"
source "$HERE/../../bin/lib.sh"

step "Stage 40: image"
require_file "$WORK_DIR/rootfs/.extracted" "stage 20 has not run - no rootfs"
require_file "$OUT_DIR/kernel/$KERNEL_IMAGE_NAME" "stage 10 has not run - no kernel"
# The image is sparse, so what it costs on disk is roughly the rootfs size.
require_disk_gb 8 "$OUT_DIR"

mkdir -p "$OUT_DIR"
build_image "$IMG_ALARM" "$HERE/../20-rootfs"

run_in_root "$IMG_ALARM" \
  --privileged \
  -v "$WORK_DIR:/work" \
  -v "$OUT_DIR:/out" \
  -v "$HERE/../..:/src:ro" \
  -e "IMG_NAME=$IMG_NAME" \
  -e "IMG_SIZE_MB=$IMG_SIZE_MB" \
  -e "IMG_HEADROOM_MB=$IMG_HEADROOM_MB" \
  -e "BOOT_SIZE_MB=$BOOT_SIZE_MB" \
  -e "KERNEL_IMAGE_NAME=$KERNEL_IMAGE_NAME" \
  -e "IMG_COMPRESS=$IMG_COMPRESS" \
  -- bash -euo pipefail /src/stages/40-image/assemble.sh

ok "image written to $OUT_DIR"
ls -lh "$OUT_DIR"/*.img* 2>/dev/null | sed 's/^/    /'
