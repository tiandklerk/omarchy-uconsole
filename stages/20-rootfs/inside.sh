#!/usr/bin/env bash
# Runs as root inside the stage-20 container. Builds /work/rootfs.
set -euo pipefail

ROOTFS=/work/rootfs
say() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }

# --- teardown --------------------------------------------------------------
# Always unmount, even on failure: a leaked bind mount on /work/rootfs/proc
# makes the next run delete parts of the container's own /proc.
cleanup() {
  set +e
  for m in dev/pts dev sys proc; do
    mountpoint -q "$ROOTFS/$m" && umount -l "$ROOTFS/$m"
  done
}
trap cleanup EXIT

# --- extract ---------------------------------------------------------------
if [[ ! -e "$ROOTFS/.extracted" ]]; then
  say "extracting base rootfs"
  rm -rf "$ROOTFS"; mkdir -p "$ROOTFS"
  # bsdtar preserves ownership, permissions, xattrs and the sparse layout that
  # GNU tar mangles for Arch Linux ARM tarballs.
  bsdtar -xpf "$TARBALL" -C "$ROOTFS"
  touch "$ROOTFS/.extracted"
else
  say "reusing extracted rootfs (delete work/rootfs to start clean)"
fi

# --- chroot plumbing -------------------------------------------------------
say "preparing chroot"
mkdir -p "$ROOTFS"/{proc,sys,dev/pts}
mountpoint -q "$ROOTFS/proc"    || mount -t proc  proc  "$ROOTFS/proc"
mountpoint -q "$ROOTFS/sys"     || mount -t sysfs sys   "$ROOTFS/sys"
mountpoint -q "$ROOTFS/dev"     || mount -o bind  /dev  "$ROOTFS/dev"
mountpoint -q "$ROOTFS/dev/pts" || mount -o bind  /dev/pts "$ROOTFS/dev/pts"
# Arch Linux ARM ships /etc/resolv.conf as a symlink into systemd-resolved's
# runtime dir, which does not exist here - cp would refuse to write through
# a dangling symlink and the chroot would have no DNS.
rm -f "$ROOTFS/etc/resolv.conf"
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

inchroot() { chroot "$ROOTFS" /bin/bash -euo pipefail -c "$*"; }

# --- pacman ----------------------------------------------------------------
say "disabling pacman's download sandbox"
# pacman 7 confines downloads with Landlock, running them as the 'alpm' user.
# Inside an emulated chroot that fails ("Landlock is not supported by the
# kernel") and every sync errors out. Harmless to disable in a build chroot.
# It has to be inside [options]; appended at the end of the file it lands in a
# repository section and pacman ignores it with only a warning.
grep -q '^DisableSandbox' "$ROOTFS/etc/pacman.conf" || \
  sed -i '/^\[options\]/a DisableSandbox' "$ROOTFS/etc/pacman.conf"

# pacman cannot work out the cachedir's mount point inside a chroot and then
# concludes there is no free space. Arch's own pacstrap disables the check for
# exactly this reason; it is restored before the image ships.
sed -i 's/^CheckSpace/#CheckSpace/' "$ROOTFS/etc/pacman.conf"

say "initialising pacman keyring"
# gpg blocks on /dev/random under emulation; point it at the non-blocking pool.
mkdir -p "$ROOTFS/etc/pacman.d/gnupg"
inchroot 'pacman-key --init' 
inchroot 'pacman-key --populate archlinuxarm'

say "updating base system"
# The stock tarball's mirror is often stale; pin the redirecting geo mirror.
echo 'Server = http://mirror.archlinuxarm.org/$arch/$repo' > "$ROOTFS/etc/pacman.d/mirrorlist"
inchroot 'pacman -Syu --noconfirm'

say "installing base packages"
mapfile -t PKGS < <(cat /src/packages/base.packages /src/packages/uconsole-extra.packages \
                    | grep -vE '^\s*(#|$)' | sort -u)
# Install in one transaction so pacman resolves conflicts once. --needed keeps
# re-runs cheap; --ask=4 auto-answers the "replace X with Y" provider prompts.
inchroot "pacman -S --noconfirm --needed base base-devel sudo networkmanager parted \
  ${PKGS[*]}"

# --- our kernel ------------------------------------------------------------
say "installing the uConsole kernel"
KREL="$(cat /out/kernel/kernel.release)"
rm -rf "$ROOTFS/usr/lib/modules/$KREL"
cp -a "/out/kernel/modules/$KREL" "$ROOTFS/usr/lib/modules/$KREL"
# Arch Linux ARM's generic tarball ships linux-aarch64; it would fight ours for
# /boot and pull in an initramfs we do not use.
inchroot 'pacman -Rdd --noconfirm linux-aarch64 || true'
inchroot "depmod -a $KREL"

# --- uConsole overlay ------------------------------------------------------
say "applying uConsole overlay"
# --chown=root:root is essential: rsync -a applies the SOURCE directory's
# ownership to the destination directory even with a trailing slash, and the
# overlay lives in the repo owned by the invoking user. Without it /etc and
# /usr end up owned by uid 1000 - the first user created on the device.
rsync -a --chown=root:root /src/overlay/etc/ "$ROOTFS/etc/"
rsync -a --chown=root:root /src/overlay/usr/ "$ROOTFS/usr/"
# NOTE: overlay/skel is applied in stage 30, *after* omarchy-settings installs.
# That package ships its own /etc/skel/.config and would otherwise clobber our
# uConsole monitor/input overrides.

# --- system configuration --------------------------------------------------
say "configuring system"
echo "$DEFAULT_HOSTNAME" > "$ROOTFS/etc/hostname"
ln -sf "/usr/share/zoneinfo/$DEFAULT_TZ" "$ROOTFS/etc/localtime"
sed -i "s/^#\(${DEFAULT_LOCALE} UTF-8\)/\1/" "$ROOTFS/etc/locale.gen"
inchroot 'locale-gen'
echo "LANG=$DEFAULT_LOCALE" > "$ROOTFS/etc/locale.conf"

cat > "$ROOTFS/etc/fstab" <<FSTAB
# <device>              <dir>            <type> <options>              <dump> <pass>
PARTUUID=%BOOT_PARTUUID% /boot           vfat   defaults,noatime        0      2
PARTUUID=%ROOT_PARTUUID% /               ext4   defaults,noatime        0      1
FSTAB

# Maintenance account. Omarchy creates the real user on first boot.
inchroot "id -u $DEFAULT_USER >/dev/null 2>&1 || useradd -m -G wheel,video,audio,input,storage -s /bin/bash $DEFAULT_USER"
inchroot "echo '$DEFAULT_USER:$DEFAULT_PASS' | chpasswd"
inchroot "echo 'root:$DEFAULT_PASS' | chpasswd"
echo '%wheel ALL=(ALL:ALL) ALL' > "$ROOTFS/etc/sudoers.d/10-wheel"
chmod 0440 "$ROOTFS/etc/sudoers.d/10-wheel"

say "enabling services"
inchroot 'systemctl enable NetworkManager systemd-timesyncd'
inchroot 'systemctl enable uconsole-firstboot-resize.service'

# ALARM's default network stack conflicts with NetworkManager.
inchroot 'systemctl disable systemd-networkd systemd-resolved 2>/dev/null || true'

say "restoring pacman's space check for the shipped system"
sed -i 's/^#CheckSpace/CheckSpace/' "$ROOTFS/etc/pacman.conf"

say "cleaning package cache"
# NOT `pacman -Scc --noconfirm`: that prompt defaults to No, so --noconfirm
# answers No and the cache is silently kept - 1.7 GB of downloaded packages
# riding along in the shipped image.
rm -rf "$ROOTFS/var/cache/pacman/pkg/"*
rm -f "$ROOTFS/etc/resolv.conf"
ln -sf /run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || true

say "rootfs size: $(du -sh --exclude=proc --exclude=sys --exclude=dev "$ROOTFS" | cut -f1)"
