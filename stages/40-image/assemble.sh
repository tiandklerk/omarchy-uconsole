#!/usr/bin/env bash
# Runs privileged in the toolbox container. Builds /out/$IMG_NAME.img.
set -euo pipefail

ROOTFS=/work/rootfs
IMG="/out/${IMG_NAME}.img"
MNT=/mnt/img
die_msg() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }
say() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }

LOOP=""
cleanup() {
  set +e
  mountpoint -q "$MNT/boot" && umount "$MNT/boot"
  mountpoint -q "$MNT"      && umount "$MNT"
  [[ -n "$LOOP" ]] && losetup -d "$LOOP"
}
trap cleanup EXIT

if [[ "$IMG_SIZE_MB" == "auto" ]]; then
  # du reports the rootfs as it sits on the build host; ext4 metadata and the
  # journal add a few percent on top, hence the 1.08 factor.
  used_mb=$(du -sm --exclude=proc --exclude=sys --exclude=dev --exclude=repo "$ROOTFS" | cut -f1)
  IMG_SIZE_MB=$(( used_mb * 108 / 100 + BOOT_SIZE_MB + IMG_HEADROOM_MB ))
  say "rootfs is ${used_mb} MiB; sizing image to ${IMG_SIZE_MB} MiB"
fi

say "creating ${IMG_SIZE_MB} MiB image"
rm -f "$IMG"
# Sparse: the file only occupies what is actually written, so a 9 GiB image
# costs ~4 GiB on disk and compresses to far less.
truncate -s "${IMG_SIZE_MB}M" "$IMG"

say "partitioning"
parted -s "$IMG" mklabel msdos
parted -s "$IMG" mkpart primary fat32 1MiB "$((BOOT_SIZE_MB + 1))MiB"
parted -s "$IMG" mkpart primary ext4  "$((BOOT_SIZE_MB + 1))MiB" 100%
parted -s "$IMG" set 1 boot on
parted -s "$IMG" set 1 lba on

# CRITICAL: force the MBR partition type to 0x0c (W95 FAT32 LBA).
#
# The Raspberry Pi firmware finds its boot partition by this type byte. parted's
# `mkpart primary fat32` does NOT reliably set it - here it left 0x83 (Linux),
# which produces a board that is completely dead at power-on: no config.txt is
# ever read, no kernel is ever loaded, and the panel never lights. The symptom
# looks like a broken kernel or a bad flash, and is neither.
# Written directly rather than via sfdisk, which Debian splits into a separate
# package: the MBR is fixed-layout, so the type byte of partition 1 is at
# offset 446 + 4 = 450. \014 is 0x0c.
printf '\014' | dd of="$IMG" bs=1 seek=450 count=1 conv=notrunc status=none
ptype=$(od -An -tx1 -j450 -N1 "$IMG" | tr -d ' ')
[[ "$ptype" == "0c" ]] || die_msg "boot partition type is 0x$ptype, expected 0x0c"
say "boot partition type set to 0x0c (FAT32 LBA)"

LOOP="$(losetup -fP --show "$IMG")"
BOOT_DEV="${LOOP}p1"; ROOT_DEV="${LOOP}p2"
say "loop device: $LOOP"

# losetup -P makes the kernel scan the partition table, but inside a container
# there is no udev to turn the resulting sysfs entries into /dev nodes, so
# ${LOOP}p1 does not exist. Create the nodes by hand from what the kernel
# reports. (partprobe/kpartx have the same problem: they rely on udev too.)
ensure_part_nodes() {
  local loopname; loopname="$(basename "$LOOP")"
  local sysdev major minor part
  for sysdev in /sys/class/block/"${loopname}"p*; do
    [[ -e "$sysdev/dev" ]] || continue
    part="/dev/$(basename "$sysdev")"
    [[ -b "$part" ]] && continue
    IFS=: read -r major minor < "$sysdev/dev"
    mknod "$part" b "$major" "$minor"
  done
}
ensure_part_nodes
[[ -b "$BOOT_DEV" && -b "$ROOT_DEV" ]] || die_msg "partition devices did not appear for $LOOP"

say "creating filesystems"
mkfs.vfat -F 32 -n UCONSOLE  "$BOOT_DEV" >/dev/null
# 256-byte inodes and no lazy init so the first boot is not spent finishing the
# filesystem on a slow SD card.
mkfs.ext4 -q -L uconsole-root -E lazy_itable_init=0,lazy_journal_init=0 "$ROOT_DEV"

# The bootloader and fstab reference partitions by PARTUUID, which is derived
# from the MBR disk signature and is stable across flashes of this image.
DISK_ID="$(blkid -o value -s PTUUID "$LOOP")"
BOOT_PARTUUID="${DISK_ID}-01"
ROOT_PARTUUID="${DISK_ID}-02"
say "PARTUUIDs: boot=$BOOT_PARTUUID root=$ROOT_PARTUUID"

say "copying root filesystem"
mkdir -p "$MNT"
mount "$ROOT_DEV" "$MNT"
# Exclude the pseudo-filesystems and our own build marker.
rsync -aHAX --numeric-ids \
  --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
  --exclude='/repo/*' --exclude='/.extracted' \
  "$ROOTFS/" "$MNT/"
# /repo is only a bind-mount point during stage 30; it has no business in a
# shipped image.
rmdir "$MNT/repo" 2>/dev/null || true
mkdir -p "$MNT"/{proc,sys,dev,boot}

say "populating the boot partition"
mount "$BOOT_DEV" "$MNT/boot"
install -Dm644 "/out/kernel/$KERNEL_IMAGE_NAME" "$MNT/boot/$KERNEL_IMAGE_NAME"
cp /out/kernel/dtbs/*.dtb "$MNT/boot/"
mkdir -p "$MNT/boot/overlays"
cp /out/kernel/overlays/*.dtbo "$MNT/boot/overlays/"
[[ -f /out/kernel/overlays/overlay_map.dtb ]] && cp /out/kernel/overlays/overlay_map.dtb "$MNT/boot/overlays/"

cp /src/overlay/boot/config.txt "$MNT/boot/config.txt"
sed "s|%ROOT_PARTUUID%|$ROOT_PARTUUID|g" /src/overlay/boot/cmdline.txt > "$MNT/boot/cmdline.txt"

say "fixing up fstab"
sed -i -e "s|%BOOT_PARTUUID%|$BOOT_PARTUUID|g" \
       -e "s|%ROOT_PARTUUID%|$ROOT_PARTUUID|g" "$MNT/etc/fstab"
cat "$MNT/etc/fstab"

say "boot partition contents"
ls -1 "$MNT/boot" | sed 's/^/    /'
printf '    overlays/: %s files\n' "$(ls "$MNT/boot/overlays" | wc -l)"

sync
umount "$MNT/boot"; umount "$MNT"; losetup -d "$LOOP"; LOOP=""

say "image: $(du -h --apparent-size "$IMG" | cut -f1) apparent, $(du -h "$IMG" | cut -f1) on disk"

# Compression is deliberately NOT done here. build.sh verifies the raw image
# first - a structural check is worth far more before the artifact is sealed -
# and compressing afterwards avoids holding a raw and a compressed copy at the
# same time on a disk-constrained builder.
say "assembled; run bin/verify-image.sh before compressing"
