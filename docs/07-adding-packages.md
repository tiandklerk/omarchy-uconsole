# Adding the optional packages

The shipped image contains **Omarchy itself** — the desktop, its settings, the
theming, the keybinds — plus everything Arch Linux ARM already provides for
aarch64. What it may not contain is some of Omarchy's optional applications,
because those have no aarch64 build and must be compiled.

`out/packages/build-report.tsv` records exactly which were built and which were
not, and the tables in [03-not-included.md](03-not-included.md) are generated
from it.

## The easy way: build them on the uConsole

This is the natural Arch workflow and it needs no emulation. The image ships
`base-devel`, so once you have booted:

```bash
git clone https://aur.archlinux.org/<package>.git
cd <package> && makepkg -si
```

A CM5 is not fast, but it is a real aarch64 machine — a package that takes an
hour under QEMU on a build host takes minutes here. For anything from Omarchy's
own repository, clone
[omacom-io/omarchy-pkgs](https://github.com/omacom-io/omarchy-pkgs) and build
from `pkgbuilds/<package>/`.

Some PKGBUILDs are tagged `arch=(x86_64)` only. If the package builds from
source rather than shipping a prebuilt binary, adding `aarch64` to that line is
usually all it needs — that is exactly what stage 30 does automatically.

## Installing packages this repo already built

Any `.pkg.tar.zst` in `out/packages/` is a finished aarch64 package. Copy them
to the device and install directly:

```bash
scp out/packages/*.pkg.tar.zst uconsole:/tmp/
# on the uConsole:
sudo pacman -U /tmp/*.pkg.tar.zst
```

## Folding them into the image instead

If you would rather rebuild the image with the extra packages baked in:

```bash
./build.sh --from omarchy      # installs whatever is in out/packages, re-images
```

This needs the root filesystem in `work/rootfs` to still exist. If it has been
cleaned, run the whole pipeline again — the package builds are cached in
`out/packages` and will not be repeated.

**Disk**: the rootfs and the image each cost roughly the size of the installed
system and exist at the same time. `make prune` reclaims the kernel build tree
mid-run.

## What will not work regardless

Packages that ship a prebuilt x86_64 binary rather than building from source
cannot be ported by adding an architecture to the PKGBUILD — there is no aarch64
binary to install. Where upstream publishes an ARM64 build of the same
application, the fix is to point the PKGBUILD's `source` at it; where they do
not, the application simply is not available on this hardware. These are listed
in [03-not-included.md](03-not-included.md).
