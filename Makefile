# Convenience wrapper around build.sh. See README.md.
.PHONY: all kernel rootfs omarchy image verify triage docs prune clean distclean binfmt

all:        ; ./build.sh
kernel:     ; ./build.sh kernel
rootfs:     ; ./build.sh rootfs
omarchy:    ; ./build.sh omarchy
image:      ; ./build.sh image

## Assert the built image is structurally bootable (no hardware needed).
verify:     ; ./bin/verify-image.sh

## Reclaim disk mid-build without losing anything you cannot rebuild cheaply.
## Drops the kernel build tree (out/kernel already holds every artifact) and
## the per-package makepkg working directories. Keeps out/, .cache/rpi-linux
## and the package cache. ~1-2 GB.
prune:
	@test -f out/kernel/kernel.release || { echo "kernel artifacts missing; refusing to prune"; exit 1; }
	rm -rf work/kbuild
	docker run --rm -v "$(CURDIR)/work:/work" alpine sh -c 'rm -rf /work/pkgbuild/*/src /work/pkgbuild/*/pkg' || true
	@df -h . | tail -1

## Re-run the aarch64 package triage and regenerate the docs it feeds.
triage:
	./bin/triage-packages.sh
	./bin/gen-not-included.sh

docs:       ; ./bin/gen-not-included.sh

## Register aarch64 emulation on the host (needed once per reboot).
binfmt:
	docker run --privileged --rm tonistiigi/binfmt --install arm64

## Drop build state but keep downloads. The rootfs is root-owned, so it has to
## be removed from inside a container.
clean:
	docker run --rm -v "$(CURDIR)/work:/work" alpine sh -c 'rm -rf /work/*' || true
	rm -rf out

## Also drop the ~2 GB kernel source and the cached tarballs.
distclean: clean
	docker run --rm -v "$(CURDIR)/.cache:/cache" alpine sh -c 'rm -rf /cache/*' || true
