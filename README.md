# omarchy-uconsole

Build a flashable **[Omarchy](https://omarchy.org) 4** image for the
**ClockworkPi uConsole** with a **Raspberry Pi Compute Module 5**.

Omarchy is x86_64-only in practice: it is distributed as an x86 ISO, and its
package repository publishes x86_64 builds. This repository builds the aarch64
half that does not exist yet, on top of a kernel that actually knows what a
uConsole is.

```
./build.sh          # → out/omarchy-uconsole-cm5.img.xz
```

> **Status: image built and verified, not yet booted.** The full pipeline has
> run end to end on an x86_64 host and produced a flashable image that passes
> all 19 structural checks in `bin/verify-image.sh` — the uConsole overlay is on
> the boot partition, `config.txt` selects it, `root=PARTUUID` resolves to the
> real root partition, and the panel/backlight modules and Omarchy are in the
> rootfs.
>
> **It has not been booted on hardware.** Verification proves the image is
> assembled correctly; it cannot prove the panel lights up. See
> [docs/05-first-boot.md](docs/05-first-boot.md) for the checklist and the
> things most likely to be wrong.

## What this actually does

Four stages, each resumable:

| Stage | What it produces |
|---|---|
| `10-kernel` | A 6.12 kernel cross-compiled from [ak-rex/rpi-linux](https://github.com/ak-rex/rpi-linux) with the uConsole panel, backlight, keyboard and PMIC drivers, plus the `clockworkpi-uconsole-cm5` device-tree overlay |
| `20-rootfs` | An Arch Linux ARM aarch64 root filesystem with the 136 Omarchy packages that already exist for aarch64 |
| `30-omarchy` | The ~27 Omarchy packages that *don't* exist for aarch64, built under emulation, then Omarchy installed |
| `40-image` | A two-partition `.img`, verified and checksummed (xz optional) |

## Requirements

- An x86_64 Linux host with Docker and patience
- **~30 GB free disk.** The rootfs and the image are each roughly the size of
  the installed system, and they exist at the same time. `make prune` reclaims
  the kernel build tree mid-run if you are tight.
- aarch64 emulation registered on the host:

  ```bash
  docker run --privileged --rm tonistiigi/binfmt --install arm64
  ```

  This must be repeated after every reboot. `build.sh` refuses to start without
  it. The kernel is cross-compiled (fast); only the Arch package builds are
  emulated (slow).

No root on the host is needed — the stages that need root get it inside
privileged containers.

## Usage

```bash
./build.sh                  # everything
./build.sh kernel           # one stage
./build.sh --from omarchy   # resume from a stage
```

Tunables live in [`config/build.env`](config/build.env) — kernel branch, image
size, hostname, default user, CM4 vs CM5.

## Security notes

- The **recovery account password is generated per build** and written to
  `out/RECOVERY-PASSWORD.txt` (gitignored). No default password ships in this
  repository.
- **sshd is off** unless you opt in by placing `uconsole-wifi.txt` on the boot
  partition; that file is deleted after first use so the passphrase does not
  linger on a readable FAT partition.
- The image currently sets `DisableSandbox` in `pacman.conf`, because
  `bcm2712_defconfig` does not build Landlock and pacman 7 refuses to run
  without it. `CONFIG_SECURITY_LANDLOCK=y` is in the kernel fragment; once a
  kernel carrying it ships, that workaround should be removed.

## Documentation

- [Architecture](docs/01-architecture.md) — why each piece is the way it is
- [Hardware](docs/02-hardware.md) — what the uConsole actually is, driver by driver
- [What's not included](docs/03-not-included.md) — every dropped package and why
- [Flashing](docs/04-flashing.md)
- [Adding the optional packages](docs/07-adding-packages.md)
- [First boot & testing](docs/05-first-boot.md)
- [Research notes](docs/06-research-notes.md) — the findings this design rests on

## Credit

The hardware enablement is not this project's work. The uConsole panel,
keyboard, PMIC and audio drivers, and the CM5 device-tree overlay, come from
**[ak-rex](https://github.com/ak-rex)** ("Rex" on the ClockworkPi forum), whose
[kernel tree](https://github.com/ak-rex/rpi-linux) and
[pi-gen images](https://github.com/ak-rex/ClockworkPi-pi-gen) are what make a
CM5 uConsole usable at all. This repository ports that work onto Arch, and
Omarchy onto ARM.

Omarchy itself is by DHH and Basecamp.
