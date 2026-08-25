# Convenience wrapper around build.sh. See README.md.
.PHONY: all kernel rootfs omarchy image verify triage docs clean distclean binfmt

all:        ; ./build.sh
kernel:     ; ./build.sh kernel
rootfs:     ; ./build.sh rootfs
omarchy:    ; ./build.sh omarchy
image:      ; ./build.sh image

## Assert the built image is structurally bootable (no hardware needed).
verify:     ; ./bin/verify-image.sh

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
