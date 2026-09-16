.PHONY: build size doctor check check-host-tools test run login fetch-edk2-ovmf clean

QEMU_TEST_DIR ?= dist/qemu
QEMU_DISK ?= $(QEMU_TEST_DIR)/disk.img
OVMF_CODE ?=
OVMF_VARS ?=

build:
	mkdir -p dist
	docker buildx build --platform linux/amd64 --progress=plain --output type=local,dest=dist .

size: build
	python3 build/size-report.py --dist dist

fetch-edk2-ovmf:
	./fetch-edk2-ovmf.sh

doctor:
	QEMU_TEST_DIR='$(QEMU_TEST_DIR)' python3 qemu/harness.py doctor

check:
	sh -n installer/install.sh \
		rootfs/configure.sh \
		build/build-rootfs.sh \
		build/build-iso.sh \
		iso/mkimg.home_installer.sh \
		iso/genapkovl-home-installer.sh \
		build/rootfs-smoke-assertions.sh \
		fetch-edk2-ovmf.sh
	sh tests/test-installer-layout.sh
	sh tests/test-installer-efi.sh
	sh tests/test-installer-safety-behavior.sh
	sh tests/test-rootfs-smoke.sh
	sh tests/test-contract.sh
	sh tests/test-installer-safety.sh
	sh tests/test-overlay-contract.sh
	sh tests/test-fetch-edk2-safety.sh
	sh tests/test-initramfs-root.sh
	python3 tests/test-qemu-paths.py
	python3 tests/test-qemu-harness.py
	python3 tests/test-qemu-graphics.py
	python3 tests/test-size-report.py
	python3 -m py_compile build/size-report.py qemu/harness.py

check-host-tools: doctor

test: doctor fetch-edk2-ovmf build
	QEMU_TEST_DIR='$(QEMU_TEST_DIR)' QEMU_DISK='$(QEMU_DISK)' \
		OVMF_CODE='$(OVMF_CODE)' OVMF_VARS='$(OVMF_VARS)' \
		python3 qemu/harness.py test --iso dist/home-installer.iso

run: doctor fetch-edk2-ovmf
	QEMU_TEST_DIR='$(QEMU_TEST_DIR)' QEMU_DISK='$(QEMU_DISK)' \
		OVMF_CODE='$(OVMF_CODE)' OVMF_VARS='$(OVMF_VARS)' \
		python3 qemu/harness.py run

login: run

clean:
	rm -rf dist
