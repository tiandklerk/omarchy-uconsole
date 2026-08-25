# Host-side toolbox for assembling the aarch64 root filesystem.
#
# This container is x86_64. It never runs aarch64 code itself - it chroots into
# the Arch Linux ARM tree, and the host's binfmt_misc qemu-aarch64 handler (with
# the F "fix binary" flag) transparently executes the aarch64 pacman inside.
# That is why bin/lib.sh insists on the binfmt registration before this runs.
FROM debian:bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
      libarchive-tools util-linux coreutils ca-certificates curl \
      xz-utils zstd rsync dosfstools e2fsprogs parted udev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
