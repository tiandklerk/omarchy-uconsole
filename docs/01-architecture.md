# Architecture

## The problem

Omarchy is an Arch Linux desktop, distributed as an x86_64 ISO with an x86_64
package repository. The uConsole is an aarch64 handheld whose display, keyboard,
battery and audio need drivers that exist in exactly one kernel tree, which is
maintained for Debian.

Neither half can be used as-is. What this repository does is build the missing
aarch64 half of Omarchy, and port the uConsole hardware enablement from Debian
to Arch. Both halves already exist; nobody had joined them.

## Why these choices

**Arch Linux ARM as the base, not Rex's Debian image.** Omarchy *is* Arch —
pacman, AUR, `omarchy-*` packages, `omarchy-update` on top of a rolling release.
Recreating it on Debian would mean reimplementing Omarchy rather than porting
it. So the base is Arch Linux ARM aarch64 and the Debian-specific parts of Rex's
work are replaced.

**Rex's kernel, not mainline or the stock Raspberry Pi kernel.** The uConsole
panel (`panel-cwu50`), backlight (`ocp8178_bl`) and the
`clockworkpi-uconsole-cm5` device-tree overlay are out of tree.
[ak-rex/rpi-linux](https://github.com/ak-rex/rpi-linux) is the tree that carries
them, and its `bcm2712_defconfig` already enables them. Hardware enablement is
distro-independent, so this transfers cleanly.

**Cross-compile the kernel, emulate the packages.** The kernel is one large
build with a well-behaved cross-compilation story, so it is built natively on
x86_64 with `aarch64-linux-gnu-` — minutes, not hours. Arch packages assume a
native toolchain and cannot be cross-built reliably, so stage 30 runs under
`qemu-aarch64`. That is slow, which is why the triage matters: it cuts the
emulated work from 202 packages to 27.

**The generic Arch Linux ARM tarball, not the `rpi` one.** The rpi flavour ships
`linux-rpi`, which would fight our kernel over `/boot` and pull in an initramfs
we do not use.

**ext4, not btrfs.** Omarchy's btrfs layout exists to serve limine-based
snapshot rollback from the boot menu. There is no boot menu on a Pi. ext4 can be
grown in place on first boot, which is what we actually need.

**No initramfs.** ext4 and the SD controller are built into the kernel, so the
boot path is firmware → `config.txt` → kernel → root. This removes mkinitcpio,
and with it a large class of ARM boot failures.

## The stages

Each stage is independently runnable and resumable. State accumulates in
`work/`, artifacts in `out/`, downloads in `.cache/`.

```
                    ┌─ ak-rex/rpi-linux ──┐
  10-kernel         │  cross-compiled     │   out/kernel/
  (x86 container)   └─ bcm2712_defconfig ─┘   ├── kernel8-uconsole.img
                       + omarchy.config       ├── dtbs/, overlays/
                                              └── modules/

                    ┌─ ArchLinuxARM tarball ┐
  20-rootfs         │  chroot + pacman      │   work/rootfs/
  (x86 + binfmt)    │  136 aarch64 packages │   base system + kernel modules
                    └─ overlay/etc, usr ────┘   + uConsole hardware config

                    ┌─ omarchy-pkgs + AUR ──┐
  30-omarchy        │  makepkg, emulated    │   out/packages/*.pkg.tar.zst
  (arm64 emulated)  │  27 packages          │   + build-report.tsv
                    └─ then install into ───┘   work/rootfs has Omarchy
                       the rootfs

  40-image          ┌─ partition, mkfs ─────┐   out/*.img.xz
  (privileged)      └─ copy, PARTUUID fixup ┘   + sha256
```

### Why stage 20 can run pacman without an ARM machine

The host registers `qemu-aarch64` in `binfmt_misc` with the `F` (fix binary)
flag. The stage-20 container is x86_64 and runs `chroot` into the aarch64 tree;
when it executes the aarch64 `pacman`, the kernel hands it to the emulator
transparently. No qemu binary needs to be copied into the chroot.

`bin/lib.sh` checks this before any stage that depends on it, because the
failure without it — `exec format error` — is opaque.

### Why overlays are applied twice

`overlay/etc` and `overlay/usr` go in during stage 20: hardware configuration
that should exist regardless of whether Omarchy installs.

`overlay/skel` goes in during stage 30, **after** `omarchy-settings`. That
package ships its own `/etc/skel/.config`, including `hypr/monitors.lua`. Our
panel geometry has to land on top of it, not underneath.

## The triage

`bin/triage-packages.sh` classifies all 210 packages in Omarchy's lists against
the Arch Linux ARM aarch64 repositories, `omarchy-pkgs`, and a hand-written
exclusion list with reasons (`packages/excluded.packages`). Its output,
`packages/triage.tsv`, drives stage 20's package list, stage 30's build queue,
and the generated [what's-not-included](03-not-included.md) document.

Rerun it when Omarchy changes its lists; everything downstream follows.

## Failure philosophy

Stage 30 does **not** stop when a package fails to build. On a port, some
packages will not build for aarch64 — a prebuilt x86 binary, an unported
dependency — and a desktop missing one optional app is worth far more than no
image. Every failure is recorded in `out/packages/build-report.tsv` with the
reason, and surfaced in the generated documentation.

The stages that *do* fail hard are the ones where continuing would produce a
plausible-looking image that cannot boot: a kernel tree without the uConsole
overlay, a missing kernel, a rootfs that never extracted.
