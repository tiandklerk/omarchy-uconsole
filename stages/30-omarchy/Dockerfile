# aarch64 package builder.
#
# Runs emulated (qemu-aarch64 via binfmt) so that makepkg produces genuine
# aarch64 binaries. Slower than cross-compiling, but PKGBUILDs assume a native
# toolchain and most of Omarchy's own packages are small or prebuilt binaries.
FROM --platform=linux/arm64 menci/archlinuxarm:base-devel

# pacman 7 sandboxes downloads with Landlock and drops to an 'alpm' user. Under
# qemu-user emulation that setup fails outright ("Landlock is not supported by
# the kernel"), so it is disabled here. The build is already confined to a
# throwaway container.
# It must go in [options]; appended at the end it lands in a repo section
# and pacman ignores it with only a warning.
RUN sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf

RUN pacman -Sy --noconfirm --needed \
      git base-devel sudo pacman-contrib rsync \
    && pacman -Scc --noconfirm

# makepkg refuses to run as root.
RUN useradd -m -s /bin/bash builder \
    && echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder

# Keep build parallelism and stripping sane under emulation.
RUN sed -i 's/^#MAKEFLAGS=.*/MAKEFLAGS="-j$(nproc)"/' /etc/makepkg.conf

USER builder
WORKDIR /build
