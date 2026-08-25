#!/usr/bin/env bash
# Runs as root in the stage-20 toolbox container. Installs Omarchy into the
# root filesystem from the locally built aarch64 packages.
set -euo pipefail

ROOTFS=/work/rootfs
say() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }

cleanup() {
  set +e
  for m in dev/pts dev sys proc repo; do
    mountpoint -q "$ROOTFS/$m" && umount -l "$ROOTFS/$m"
  done
}
trap cleanup EXIT

mkdir -p "$ROOTFS"/{proc,sys,dev/pts,repo}
mountpoint -q "$ROOTFS/proc"    || mount -t proc  proc "$ROOTFS/proc"
mountpoint -q "$ROOTFS/sys"     || mount -t sysfs sys  "$ROOTFS/sys"
mountpoint -q "$ROOTFS/dev"     || mount -o bind /dev  "$ROOTFS/dev"
mountpoint -q "$ROOTFS/dev/pts" || mount -o bind /dev/pts "$ROOTFS/dev/pts"
mountpoint -q "$ROOTFS/repo"    || mount -o bind /repo "$ROOTFS/repo"
# Arch Linux ARM ships /etc/resolv.conf as a symlink into systemd-resolved's
# runtime dir, which does not exist here - cp would refuse to write through
# a dangling symlink and the chroot would have no DNS.
rm -f "$ROOTFS/etc/resolv.conf"
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

inchroot() { chroot "$ROOTFS" /bin/bash -euo pipefail -c "$*"; }

# See stage 20: pacman's space check cannot resolve a mount point in a chroot.
sed -i 's/^CheckSpace/#CheckSpace/' "$ROOTFS/etc/pacman.conf"

# --- pacman repositories ---------------------------------------------------
say "registering package repositories"
# Upstream's aarch64 repo currently holds only omarchy-keyring, but that is the
# package we need for signature trust, and the repo will fill out over time.
if ! grep -q '^\[omarchy\]' "$ROOTFS/etc/pacman.conf"; then
  cat >> "$ROOTFS/etc/pacman.conf" <<PACMAN

[omarchy]
SigLevel = Optional TrustAll
Server = ${OMARCHY_AARCH64_REPO_URL}
PACMAN
fi
# Our locally built packages take priority: listed first would shadow the
# distro, listed last means we only supply what nothing else provides.
if ! grep -q '^\[uconsole\]' "$ROOTFS/etc/pacman.conf"; then
  cat >> "$ROOTFS/etc/pacman.conf" <<'PACMAN'

[uconsole]
SigLevel = Optional TrustAll
Server = file:///repo
PACMAN
fi

inchroot 'pacman -Sy --noconfirm' || true

# --- install ---------------------------------------------------------------
say "installing Omarchy"
# Install what we actually managed to build, so a package that failed to
# compile for aarch64 does not abort the whole transaction.
mapfile -t BUILT < <(awk -F'\t' '$2=="built"{print $1}' /repo/build-report.tsv)
say "installing ${#BUILT[@]} locally built packages"

for pkg in "${BUILT[@]}"; do
  if inchroot "pacman -S --noconfirm --needed '$pkg'" 2>/dev/null; then
    echo "  installed $pkg"
  else
    echo "  SKIPPED  $pkg (dependency could not be satisfied on aarch64)"
    echo "$pkg" >> /repo/not-installed.txt
  fi
done

# --- uConsole user defaults, applied last ---------------------------------
# omarchy-settings ships its own /etc/skel/.config; our panel geometry and
# input tuning must land on top of it, not under it.
say "applying uConsole user defaults over Omarchy's skel"
rsync -a /src/overlay/skel/ "$ROOTFS/etc/skel/"

# Seed the maintenance account too, since it was created before Omarchy
# installed and so never picked up /etc/skel.
for home in "$ROOTFS"/home/*; do
  [[ -d "$home" ]] || continue
  user="$(basename "$home")"
  rsync -a --ignore-existing "$ROOTFS/etc/skel/." "$home/"
  rsync -a /src/overlay/skel/ "$home/"
  chroot "$ROOTFS" chown -R "$user:$user" "/home/$user"
done

say "enabling the display manager"
inchroot 'systemctl enable sddm' || echo "  sddm not installed; Omarchy will start from a TTY"

say "restoring pacman's space check for the shipped system"
sed -i 's/^#CheckSpace/CheckSpace/' "$ROOTFS/etc/pacman.conf"

inchroot 'pacman -Scc --noconfirm >/dev/null 2>&1' || true
say "done"
