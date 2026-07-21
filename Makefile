.PHONY: build fetch-edk2-ovmf test login clean

QEMU_TEST_DIR ?= dist/qemu
QEMU_DISK ?= $(QEMU_TEST_DIR)/disk.qcow2
OVMF_CODE ?=
OVMF_VARS ?=

build:
	mkdir -p dist
	docker buildx build --platform linux/amd64 --progress=plain --output type=local,dest=dist .

fetch-edk2-ovmf:
	./fetch-edk2-ovmf.sh

test: build fetch-edk2-ovmf
	OVMF_CODE='$(OVMF_CODE)' OVMF_VARS='$(OVMF_VARS)' QEMU_DISK='$(QEMU_DISK)' ./qemu/test.sh dist/home-installer.iso

login: fetch-edk2-ovmf
	OVMF_CODE='$(OVMF_CODE)' OVMF_VARS='$(OVMF_VARS)' QEMU_DISK='$(QEMU_DISK)' ./qemu/login.sh

clean:
	rm -rf dist
