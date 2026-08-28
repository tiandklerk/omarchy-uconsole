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
  -v "$OUT_DIR/packages:/repo:ro" \
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

# Mount READ-ONLY. A read-write mount updates the ext4 superblock (mount count,
# last-mount time), which changes the image bytes and invalidates the published
# sha256 - verifying an image must not modify it.
mkdir -p /m
mount -o ro "${LOOP}p2" /m    || { echo "cannot mount root partition"; exit 1; }
mount -o ro "${LOOP}p1" /m/boot || { echo "cannot mount boot partition"; exit 1; }

echo
echo "Partition table"
# The Raspberry Pi firmware locates its boot partition by MBR type byte. A
# FAT32 filesystem sitting in a partition typed 0x83 is invisible to it, and
# the board is simply dead at power-on. This check exists because that shipped
# once: every file was correct and the image still could not boot.
PTYPE=$(od -An -tx1 -j450 -N1 "$IMG_FILE" | tr -d " ")
[[ "$PTYPE" == "0c" ]]
chk "boot partition MBR type is 0x0c FAT32 LBA (found 0x$PTYPE)" $?
[[ "$(od -An -tx1 -j446 -N1 "$IMG_FILE" | tr -d " ")" == "80" ]]
chk "boot partition is marked bootable" $?

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
# A display without a GPU renders nothing: Mesa drops to llvmpipe and the
# compositor shows a black screen on a working panel.
grep -qE "^dtoverlay=vc4-kms-v3d(-pi5)?$" /m/boot/config.txt
chk "GPU overlay enabled (vc4-kms-v3d) - without it EGL fails and nothing draws" $?
[[ -f /m/boot/overlays/vc4-kms-v3d-pi5.dtbo ]]; chk "vc4-kms-v3d-pi5.dtbo present" $?
# Audio needs BOTH of these on a CM5 and each fails silently alone: the wrong
# audremap plays into a dummy codec, and without the GPIO the amp is unpowered.
grep -q "^dtoverlay=audremap-pi5,pins_12_13$" /m/boot/config.txt
chk "CM5 audio overlay (audremap-pi5) - plain audremap is inert on a CM5" $?
grep -q "^gpio=11=op,dh$" /m/boot/config.txt
chk "speaker amplifier enable (gpio=11=op,dh)" $?
[[ -f /m/boot/overlays/audremap-pi5.dtbo ]]; chk "audremap-pi5.dtbo present" $?

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

# Every package we went to the trouble of building for aarch64 must actually be
# IN the image. This has been wrong twice: the rootfs was populated from a repo
# snapshot taken before later packages finished building, so xdg-terminal-exec
# and then mise-bin shipped missing and broke Omarchy at runtime with
# "command not found". Building a package is not installing it.
missing=""
for pkg in /repo/*.pkg.tar.*; do
  [[ -e "$pkg" ]] || continue
  base=$(basename "$pkg"); name=${base%-[0-9]*}
  ls -d /m/var/lib/pacman/local/${name}-[0-9]* >/dev/null 2>&1 || missing="$missing $name"
done
[[ -z "$missing" ]]
chk "all locally built packages are installed in the image${missing:+ - MISSING:$missing}" $?

# suspend hard-locks this hardware (s2idle never resumes), so the sleep targets
# must be masked and the Omarchy menu entry hidden.
[[ -L /m/etc/systemd/system/suspend.target ]]; chk "suspend.target masked" $?
[[ -e /m/etc/skel/.local/state/omarchy/toggles/suspend-off ]]
chk "suspend menu entry hidden" $?

echo
if (( fail )); then
  printf "\033[1;31mimage verification FAILED\033[0m\n"; exit 1
fi
printf "\033[1;32mimage verification passed\033[0m\n"
'
