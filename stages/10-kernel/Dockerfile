# Cross-compilation toolchain for the uConsole kernel.
# Runs natively on x86_64 and cross-compiles to aarch64, which is roughly an
# order of magnitude faster than building under QEMU emulation.
FROM debian:bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential crossbuild-essential-arm64 \
      bc bison flex libssl-dev make libc6-dev libncurses-dev \
      device-tree-compiler kmod cpio rsync git ca-certificates zstd xz-utils \
    && rm -rf /var/lib/apt/lists/*

ENV ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
WORKDIR /build
