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

> **Status: built, not yet booted.** Every stage runs and produces artifacts on
> an x86_64 Linux host. Nothing in here has been booted on real hardware yet.
> See [docs/05-first-boot.md](docs/05-first-boot.md) for what to check first and
> what is most likely to be wrong.

## What this actually does

Four stages, each resumable:

| Stage | What it produces |
|---|---|
| `10-kernel` | A 6.12 kernel cross-compiled from [ak-rex/rpi-linux](https://github.com/ak-rex/rpi-linux) with the uConsole panel, backlight, keyboard and PMIC drivers, plus the `clockworkpi-uconsole-cm5` device-tree overlay |
| `20-rootfs` | An Arch Linux ARM aarch64 root filesystem with the 136 Omarchy packages that already exist for aarch64 |
| `30-omarchy` | The ~27 Omarchy packages that *don't* exist for aarch64, built under emulation, then Omarchy installed |
| `40-image` | A two-partition `.img`, checksummed and xz-compressed |

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

## Documentation

- [Architecture](docs/01-architecture.md) — why each piece is the way it is
- [Hardware](docs/02-hardware.md) — what the uConsole actually is, driver by driver
- [What's not included](docs/03-not-included.md) — every dropped package and why
- [Flashing](docs/04-flashing.md)
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
