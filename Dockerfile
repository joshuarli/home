ARG BUILDARCH
ARG TARGETARCH

FROM alpine:3.24.1 AS rootfs
ARG BUILDARCH
ARG TARGETARCH
ENV BUILDARCH=$BUILDARCH TARGETARCH=$TARGETARCH

RUN apk add --no-cache apk-tools-static binutils lddtree kmod qemu-x86_64 tar gzip
COPY rootfs-packages.txt /work/rootfs-packages.txt
COPY rootfs/configure.sh /work/configure-rootfs.sh
COPY build/build-rootfs.sh /work/build-rootfs.sh
RUN chmod +x /work/configure-rootfs.sh /work/build-rootfs.sh && /work/build-rootfs.sh

FROM alpine:3.24.1 AS iso-tools

RUN --mount=type=cache,target=/var/cache/apk \
    apk add abuild alpine-conf git grub mtools squashfs-tools zstd-libs syslinux xorriso tar gzip

FROM iso-tools AS aports

ARG ALPINE_APORTS_BRANCH
RUN tag=$(cut -d. -f1,2 /etc/alpine-release) && \
    branch=${ALPINE_APORTS_BRANCH:-"$tag-stable"} && \
    git clone --depth 1 --branch "$branch" https://gitlab.alpinelinux.org/alpine/aports.git /work/aports && \
    sed -i 's/ --no-chown//' /work/aports/scripts/mkimage.sh

FROM iso-tools AS iso

COPY --from=rootfs /work/out/rootfs.tar.gz /work/rootfs.tar.gz
COPY --from=aports /work/aports /work/aports
COPY iso /work/iso
COPY build/build-iso.sh /work/build-iso.sh
RUN --mount=type=cache,target=/root/.abuild \
    chmod +x /work/iso/*.sh /work/build-iso.sh && /work/build-iso.sh

FROM iso AS patched

COPY installer/install.sh /work/installer/install.sh
RUN chmod +x /work/installer/install.sh && \
    xorriso -indev /work/out/home-installer.iso \
        -outdev /work/out/home-installer-patched.iso \
        -map /work/installer/install.sh /home-installer/install.sh \
        -boot_image any replay \
        -end

FROM scratch AS artifact
COPY --from=patched /work/out/home-installer-patched.iso /home-installer.iso
