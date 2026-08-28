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

# --- apply Omarchy to the system ------------------------------------------
# Installing the packages is not the same as applying Omarchy. The ISO calls
# omarchy-apply-system in the target chroot to run install/config, the hardware
# setup, the login (sddm) setup and the post-install steps.
#
# --defer-provisioning is the mode built for prebuilt images: it applies system
# setup without an install user, and leaves the account creation to first boot.
# That is exactly our situation - we cannot know the owner's username at build
# time.
# --- steps that cannot complete in a build chroot -------------------------
# Omarchy's config/all.sh runs every step with `set -e`, so one failure aborts
# everything after it - including the sddm login setup and the post-install
# steps. Two steps cannot succeed here, for different reasons:
#
#   snapper.sh   - snapper is deliberately not installed (no bootloader on a Pi
#                  to hang snapshot rollback off). Replaced with a no-op.
#   firewall.sh  - ufw probes the running kernel for an iptables version and
#                  fails against the builder's kernel. Deferred to first boot on
#                  real hardware via uconsole-firstboot-omarchy.service.
DEFER_MARKER="$ROOTFS/var/lib/uconsole/omarchy-deferred"
mkdir -p "$(dirname "$DEFER_MARKER")"
: > "$DEFER_MARKER"

FIREWALL_STEP="$ROOTFS/usr/share/omarchy/install/config/firewall.sh"
if [[ -f "$FIREWALL_STEP" && ! -f "$FIREWALL_STEP.deferred" ]]; then
  mv "$FIREWALL_STEP" "$FIREWALL_STEP.deferred"
  cat > "$FIREWALL_STEP" <<'NOFW'
#!/bin/bash
# Replaced by omarchy-uconsole. ufw cannot determine an iptables version inside
# a build chroot; the real step runs on first boot from
# uconsole-firstboot-omarchy.service.
echo "deferring firewall setup to first boot"
NOFW
  chmod +x "$FIREWALL_STEP"
  echo "/usr/share/omarchy/install/config/firewall.sh.deferred" >> "$DEFER_MARKER"
  echo "  deferred the firewall step to first boot"
fi

# Omarchy's config/all.sh runs snapper.sh unconditionally and the script dies
# under set -e when snapper is missing (exit 127), aborting everything after it
# - including the sddm login setup and the post-install steps. snapper is
# deliberately not installed here: there is no bootloader on a Pi to hang
# snapshot rollback off (see docs/03-not-included.md). So the step is replaced
# with an explicit no-op rather than allowed to take the rest of the run down.
SNAPPER_STEP="$ROOTFS/usr/share/omarchy/install/config/snapper.sh"
if [[ -f "$SNAPPER_STEP" ]]; then
  cat > "$SNAPPER_STEP" <<'NOSNAP'
#!/bin/bash
# Replaced by omarchy-uconsole. snapper is not installed on this image: the
# Raspberry Pi bootloader lives in SPI EEPROM and reads config.txt, so there is
# no boot menu for snapshot-rollback entries.
echo "skipping snapper setup (not applicable to a Raspberry Pi boot path)"
NOSNAP
  chmod +x "$SNAPPER_STEP"
  echo "  neutralised the snapper setup step (package deliberately absent)"
fi

say "applying Omarchy system setup (deferred provisioning)"
if chroot "$ROOTFS" /bin/bash -c \
     'omarchy-apply-system --defer-provisioning --first-install' 2>&1 | tail -30; then
  ok_apply=1
else
  ok_apply=0
  echo "  WARNING: omarchy-apply-system did not complete cleanly."
  echo "  The packages are installed and /etc/skel is seeded, so the desktop"
  echo "  should still come up; some system tuning may be missing."
fi
# Keep the log where it can be read after flashing, and copy it out for review.
cp "$ROOTFS/var/log/omarchy-install.log" /repo/omarchy-install.log 2>/dev/null || true

# --- arm first-boot user creation -----------------------------------------
# The provisioning unit ships in the omarchy package but is deliberately not
# enabled; whatever stages a deferred install is responsible for arming it.
say "arming first-boot user provisioning"
PROV_UNIT="$ROOTFS/usr/share/omarchy/install/provisioning/omarchy-provision-owner.service"
if [[ -f "$PROV_UNIT" ]]; then
  install -Dm644 "$PROV_UNIT" "$ROOTFS/etc/systemd/system/omarchy-provision-owner.service"
  mkdir -p "$ROOTFS/var/lib/omarchy/provisioning"
  touch "$ROOTFS/var/lib/omarchy/provisioning/pending"
  inchroot 'systemctl enable omarchy-provision-owner.service' \
    && echo "  first boot will ask for the owner account on tty1"
else
  echo "  provisioning unit not found; first boot will land on the '$DEFAULT_USER' account instead"
fi

# --- uConsole user defaults, applied last ---------------------------------
# omarchy-settings ships its own /etc/skel/.config; our panel geometry and
# input tuning must land on top of it, not under it.
say "applying uConsole user defaults over Omarchy's skel"
# --chown=root:root is essential: rsync -a applies the SOURCE directory's
# ownership to the destination directory even with a trailing slash, and the
# overlay lives in the repo owned by the invoking user. Without it /etc and
# /usr end up owned by uid 1000 - the first user created on the device.
rsync -a --chown=root:root /src/overlay/skel/ "$ROOTFS/etc/skel/"

# Seed the maintenance account too, since it was created before Omarchy
# installed and so never picked up /etc/skel.
for home in "$ROOTFS"/home/*; do
  [[ -d "$home" ]] || continue
  user="$(basename "$home")"
  rsync -a --ignore-existing "$ROOTFS/etc/skel/." "$home/"
  rsync -a --chown=root:root /src/overlay/skel/ "$home/"
  chroot "$ROOTFS" chown -R "$user:$user" "/home/$user"
done

# --- greeter rotation ------------------------------------------------------
# sddm runs its OWN Hyprland instance for the greeter, from
# /usr/share/sddm/hyprland.lua. It never reads the user's
# ~/.config/hypr/monitors.lua, so without this the login screen renders sideways
# on a panel that is mounted rotated - even though the desktop behind it is
# correct.
say "rotating the sddm greeter for the uConsole panel"
GREETER="$ROOTFS/usr/share/sddm/hyprland.lua"
if [[ -f "$GREETER" ]] && ! grep -q "uConsole" "$GREETER"; then
  cat >> "$GREETER" <<'LUA'

-- uConsole: the panel is mounted rotated 90 degrees in the shell. The greeter
-- runs its own Hyprland and does not read the user's monitors.lua, so the
-- transform has to be repeated here.
hl.monitor({ output = "DSI-1", mode = "preferred", position = "0x0", scale = 1, transform = 3 })
hl.monitor({ output = "DSI-2", mode = "preferred", position = "0x0", scale = 1, transform = 3 })
LUA
  echo "  greeter rotated"
else
  echo "  greeter config not found or already patched"
fi

say "enabling deferred first-boot setup"
inchroot 'systemctl enable uconsole-firstboot-omarchy.service' || \
  echo "  could not enable the deferred-setup unit"

say "enabling the display manager"
inchroot 'systemctl enable sddm' || echo "  sddm not installed; Omarchy will start from a TTY"

# --- repoint pacman at ARM repositories ------------------------------------
# omarchy-apply-system runs install/post-install/pacman.sh, which installs
# Omarchy's own pacman.conf and mirrorlist. Both are x86_64-shaped and leave an
# aarch64 system unable to install ANYTHING:
#
#   * the mirrorlist points at mirror.omarchy.org, which serves x86_64 only -
#     every aarch64 package 404s
#   * [omarchy] uses pkgs.omarchy.org/stable/$arch; only the bare /aarch64 path
#     is published, so stable/ 404s too
#   * it declares [multilib], which does not exist on aarch64 at all
#   * it drops [alarm] and [aur], the Arch Linux ARM repos this system was
#     installed from
#
# This has to run AFTER apply-system, because that is what overwrites it.
say "repointing pacman at the Arch Linux ARM repositories"
echo 'Server = http://mirror.archlinuxarm.org/$arch/$repo' > "$ROOTFS/etc/pacman.d/mirrorlist"

# Keep Omarchy's [options] block (Color, ILoveCandy, ParallelDownloads and so
# on) and replace only the repository list, which is the part that is wrong for
# aarch64.
awk '/^\[core\]/{exit} {print}' "$ROOTFS/etc/pacman.conf" > "$ROOTFS/etc/pacman.conf.new"
cat >> "$ROOTFS/etc/pacman.conf.new" <<'PACMAN'
[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

# Arch Linux ARM's own repositories - the base system was installed from these
# and Omarchy's generated config drops them.
[alarm]
Include = /etc/pacman.d/mirrorlist

[aur]
Include = /etc/pacman.d/mirrorlist

# Upstream publishes aarch64 at the bare path; stable/aarch64 returns 404.
[omarchy]
SigLevel = Optional TrustAll
Server = https://pkgs.omarchy.org/$arch
PACMAN
mv "$ROOTFS/etc/pacman.conf.new" "$ROOTFS/etc/pacman.conf"
# pacman 7 sandboxes downloads with Landlock. Our kernel now builds
# CONFIG_SECURITY_LANDLOCK=y with landlock in CONFIG_LSM, so the sandbox works
# and DisableSandbox is NOT needed - leaving it would ship a distro with a
# security feature switched off for no reason.
#
# If a kernel without Landlock is ever used here, pacman fails with
# "restricting filesystem access failed because Landlock is not supported by
# the kernel"; the fix is to add DisableSandbox under [options].
sed -i '/^DisableSandbox$/d' "$ROOTFS/etc/pacman.conf"
echo "  repositories: $(grep -cE '^\[' "$ROOTFS/etc/pacman.conf") sections"

say "restoring pacman's space check for the shipped system"
sed -i 's/^#CheckSpace/CheckSpace/' "$ROOTFS/etc/pacman.conf"

# NOT `pacman -Scc --noconfirm`: that prompt defaults to No, so --noconfirm
# answers No and the cache is silently kept in the shipped image.
rm -rf "$ROOTFS/var/cache/pacman/pkg/"*
# Remove the build container's resolv.conf, copied in at the top so the chroot
# could reach the mirrors. Leaving it ships the build host's DNS config and
# breaks name resolution on the device.
say "restoring DNS configuration for the shipped system"
rm -f "$ROOTFS/etc/resolv.conf"
ln -sf /run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"
mkdir -p "$ROOTFS/etc/NetworkManager/conf.d"
cat > "$ROOTFS/etc/NetworkManager/conf.d/10-dns-resolved.conf" <<'NMDNS'
# Hand DNS to systemd-resolved rather than letting NetworkManager write
# /etc/resolv.conf itself; resolved is enabled on this image.
[main]
dns=systemd-resolved
NMDNS

say "done"
