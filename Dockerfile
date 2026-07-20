ARG BUILDARCH
ARG TARGETARCH

FROM alpine:latest AS rootfs
ARG BUILDARCH
ARG TARGETARCH
ENV BUILDARCH=$BUILDARCH TARGETARCH=$TARGETARCH

RUN apk add --no-cache apk-tools-static qemu-x86_64 tar gzip
COPY rootfs-packages.txt /work/rootfs-packages.txt
COPY rootfs/configure.sh /work/configure-rootfs.sh
COPY build/build-rootfs.sh /work/build-rootfs.sh
RUN chmod +x /work/configure-rootfs.sh /work/build-rootfs.sh && /work/build-rootfs.sh

FROM alpine:latest AS iso

RUN apk add --no-cache abuild alpine-conf git grub mtools squashfs-tools syslinux xorriso tar gzip
COPY --from=rootfs /work/out/rootfs.tar.gz /work/rootfs.tar.gz
COPY installer/install.sh /work/installer/install.sh
COPY iso /work/iso
COPY build/build-iso.sh /work/build-iso.sh
RUN chmod +x /work/installer/install.sh /work/iso/*.sh /work/build-iso.sh && /work/build-iso.sh

FROM scratch AS artifact
COPY --from=iso /work/out/home-installer.iso /home-installer.iso
