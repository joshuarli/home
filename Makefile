.PHONY: build fetch-edk2-ovmf check-host-tools test login clean

QEMU_TEST_DIR ?= dist/qemu
QEMU_DISK ?= $(QEMU_TEST_DIR)/disk.img
OVMF_CODE ?=
OVMF_VARS ?=

build:
	mkdir -p dist
	docker buildx build --platform linux/amd64 --progress=plain --output type=local,dest=dist .

fetch-edk2-ovmf:
	./fetch-edk2-ovmf.sh

check-host-tools:
	@for command in qemu-system-x86_64 qemu-img bsdtar; do \
		command -v "$${command}" >/dev/null 2>&1 || { \
			echo "required host command is missing: $${command}" >&2; exit 1; \
		}; \
	done

test: check-host-tools
	$(MAKE) build
	QEMU_DISK='$(QEMU_DISK)' ./qemu/test.sh dist/home-installer.iso

login: fetch-edk2-ovmf
	OVMF_CODE='$(OVMF_CODE)' OVMF_VARS='$(OVMF_VARS)' QEMU_DISK='$(QEMU_DISK)' ./qemu/login.sh

clean:
	rm -rf dist
