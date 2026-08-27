# Flashing

## What you get

```
out/omarchy-uconsole-cm5.img        flash this (~11 GiB)
out/omarchy-uconsole-cm5.sha256     checksum
```

An `.img.xz` appears alongside it when the build compresses (`IMG_COMPRESS=xz`,
the default when there is disk headroom for it).

The image is sized to the installed system plus about 1.5 GiB of headroom. The
reference build comes out at **11 GiB**, so use a **16 GB card or larger** —
`ls -lh out/` confirms the size of yours. Root is grown to fill whatever card it
lands on during first boot, so a bigger card is fine and needs no action.

Note the file is sparse: it reports 11 GiB but occupies about 8.4 GiB on disk.
`dd` still writes the full 11 GiB to the card.

## Verify first

```bash
cd out && sha256sum -c omarchy-uconsole-cm5.sha256
```

## Flash

Identify the card carefully — `lsblk` before and after inserting it. **Writing
to the wrong device destroys it.**

With Raspberry Pi Imager (choose "Use custom image"), or:

```bash
sudo dd if=out/omarchy-uconsole-cm5.img of=/dev/sdX bs=4M status=progress conv=fsync
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

## First boot

The image uses Omarchy's **deferred provisioning**: it ships without your
account, and on first boot `omarchy-provision-owner` runs on tty1 — before the
display manager — and asks you to create the owner account. Answer it and the
desktop starts.

Behind that there is a recovery account, for when provisioning fails or the
panel does not come up. Its password is **generated per build** and written to:

```
out/RECOVERY-PASSWORD.txt
```

That file is gitignored and never published. It is not `alarm`/`alarm` — those
are the Arch Linux ARM defaults, they are public knowledge, and this image can
run sshd, so shipping them would be a real vulnerability rather than an
inconvenience.

To choose your own instead:

```bash
DEFAULT_PASS='something-you-picked' ./build.sh
```

If you flashed an image someone else built, change it immediately:

```bash
sudo passwd alarm && sudo passwd -l root
```

If provisioning does not appear, the image fell back to plain login — use the
maintenance account and check `journalctl -u omarchy-provision-owner`.

## If it does not boot

The panel staying dark is the common failure and does not necessarily mean the
kernel failed — the panel driver is a module and loads a moment after boot.

Order of things to check is in [05-first-boot.md](05-first-boot.md).
