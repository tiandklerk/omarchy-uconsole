# Flashing

## What you get

```
out/omarchy-uconsole-cm5.img.xz     compressed, flash this
out/omarchy-uconsole-cm5.img        uncompressed
out/omarchy-uconsole-cm5.sha256     checksums for both
```

The image is sized to the installed system plus about 1.5 GiB of headroom, so
its size depends on how many packages built for aarch64 — expect somewhere
between 8 and 16 GiB uncompressed. `ls -lh out/` tells you. Use a card at least
that large; root is grown to fill whatever card it lands on during first boot,
so bigger is fine and needs no action.

## Verify first

```bash
cd out && sha256sum -c omarchy-uconsole-cm5.sha256
```

## Flash

Identify the card carefully — `lsblk` before and after inserting it. **Writing
to the wrong device destroys it.**

With Raspberry Pi Imager (choose "Use custom image"), or:

```bash
xzcat out/omarchy-uconsole-cm5.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

Do not use Imager's OS-customisation options (hostname, wifi, SSH). They write
Raspberry Pi OS-specific files that nothing in this image reads.

## Before first boot

Everything needed is already on the FAT partition. The one thing worth doing is
re-reading `config.txt` if your uConsole differs from the reference build — for
example a CM4 rather than a CM5, where you would set `UC_MODEL=cm4` and rebuild
rather than editing the image.

If you want serial console access for debugging a boot that does not reach the
display, add to `config.txt` on the FAT partition:

```
enable_uart=1
```

and add `console=serial0,115200` to `cmdline.txt`.

## First login

The image ships a maintenance account only — Omarchy provisions the real user
itself on first boot.

```
user: alarm
pass: alarm
```

**Change it.** These are the Arch Linux ARM defaults and are public. `root` has
the same password.

Set your own before building instead by editing `DEFAULT_USER` / `DEFAULT_PASS`
in `config/build.env`.

## If it does not boot

The panel staying dark is the common failure and does not necessarily mean the
kernel failed — the panel driver is a module and loads a moment after boot.

Order of things to check is in [05-first-boot.md](05-first-boot.md).
