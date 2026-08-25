#!/usr/bin/env bash
# Inspect a built image and assert the things that must be true for it to boot
# a uConsole. This is the closest we can get to testing without hardware: it
# will not tell you the panel lights up, but it will catch every "the image was
# assembled wrong" failure before you spend twenty minutes flashing a card.
#
#   bin/verify-image.sh [path/to/image.img]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../config/build.env"
source "$HERE/lib.sh"

IMG="${1:-$OUT_DIR/${IMG_NAME}.img}"
require_file "$IMG" "no image at $IMG (pass one as an argument)"

step "Verifying $(basename "$IMG")"
build_image "$IMG_ALARM" "$HERE/../stages/20-rootfs"

run_in_root "$IMG_ALARM" --privileged \
  -v "$(cd "$(dirname "$IMG")" && pwd):/img" \
  -e "IMG_FILE=/img/$(basename "$IMG")" \
  -e "UC_MODEL=$UC_MODEL" \
  -e "KERNEL_IMAGE_NAME=$KERNEL_IMAGE_NAME" \
  -- bash -uo pipefail -c '
# NOTE: deliberately no `set -e`. Every check below is a command whose non-zero
# exit *is* the result being reported; errexit would abort on the first failure
# instead of reporting all of them.
fail=0
chk() { # chk <description> <condition-already-evaluated-as-exit-code>
  if [[ $2 -eq 0 ]]; then printf "  \033[1;32m✓\033[0m %s\n" "$1"
  else printf "  \033[1;31m✗\033[0m %s\n" "$1"; fail=1; fi
}

LOOP=$(losetup -fP --show "$IMG_FILE")
n=$(basename "$LOOP")
for d in /sys/class/block/${n}p*; do
  IFS=: read -r ma mi < "$d/dev"
  [[ -b "/dev/$(basename "$d")" ]] || mknod "/dev/$(basename "$d")" b "$ma" "$mi"
done
trap "umount -l /m/boot /m 2>/dev/null; losetup -d $LOOP" EXIT

mkdir -p /m
mount "${LOOP}p2" /m    || { echo "cannot mount root partition"; exit 1; }
mount "${LOOP}p1" /m/boot || { echo "cannot mount boot partition"; exit 1; }

echo
echo "Boot partition"
[[ -f /m/boot/$KERNEL_IMAGE_NAME ]]; chk "kernel image ($KERNEL_IMAGE_NAME)" $?
[[ -f /m/boot/config.txt ]];         chk "config.txt" $?
[[ -f /m/boot/cmdline.txt ]];        chk "cmdline.txt" $?
ls /m/boot/bcm2712-*.dtb >/dev/null 2>&1; chk "bcm2712 device trees present" $?
[[ -f /m/boot/overlays/clockworkpi-uconsole-${UC_MODEL}.dtbo ]]
chk "clockworkpi-uconsole-${UC_MODEL}.dtbo (the panel/keyboard/battery overlay)" $?
grep -q "^dtoverlay=clockworkpi-uconsole-${UC_MODEL}" /m/boot/config.txt
chk "config.txt selects the uConsole overlay" $?
grep -q "^dtparam=ant2" /m/boot/config.txt; chk "external wifi antenna enabled" $?

echo
echo "Boot arguments"
ROOT_UUID=$(blkid -o value -s PARTUUID "${LOOP}p2")
grep -q "root=PARTUUID=${ROOT_UUID}" /m/boot/cmdline.txt
chk "cmdline root=PARTUUID matches the real root partition" $?
grep -q "fbcon=rotate:" /m/boot/cmdline.txt; chk "console rotation set" $?
grep -q "%ROOT_PARTUUID%\|%BOOT_PARTUUID%" /m/boot/cmdline.txt /m/etc/fstab
[[ $? -ne 0 ]]; chk "no unsubstituted placeholders left" $?

echo
echo "Root filesystem"
KREL=$(ls /m/usr/lib/modules 2>/dev/null | head -1)
[[ -n "$KREL" ]]; chk "kernel modules installed (${KREL:-none})" $?
[[ -f /m/usr/lib/modules/$KREL/modules.dep ]]; chk "depmod has run" $?
find /m/usr/lib/modules -name "panel-cwu50.ko*" | grep -q .; chk "panel driver module present" $?
find /m/usr/lib/modules -name "ocp8178_bl.ko*"  | grep -q .; chk "backlight driver module present" $?
[[ -x /m/usr/bin/Hyprland ]] || [[ -x /m/usr/bin/hyprland ]]; chk "Hyprland installed" $?
[[ -x /m/usr/bin/omarchy ]] || [[ -d /m/usr/share/omarchy ]]; chk "Omarchy installed" $?
[[ -f /m/etc/skel/.config/hypr/monitors.lua ]]; chk "uConsole monitor config seeded into /etc/skel" $?
grep -q "transform = 3" /m/etc/skel/.config/hypr/monitors.lua 2>/dev/null
chk "panel rotation configured (transform 3)" $?
[[ -f /m/etc/udev/rules.d/99-uconsole-power.rules ]]; chk "battery charge-rate rule present" $?
[[ -x /m/usr/local/bin/uconsole-firstboot-resize ]]; chk "first-boot resize script present" $?

echo
if (( fail )); then
  printf "\033[1;31mimage verification FAILED\033[0m\n"; exit 1
fi
printf "\033[1;32mimage verification passed\033[0m\n"
'
