FROM alpine:3.24.1 AS upstream-dwl-build

# Alpine 3.24.1 does not ship a dwl package.  Build the pinned upstream
# release with its stock configuration in a build-only stage; the compiler,
# headers and source archive never enter the target rootfs.  The upstream
# default keeps XWayland disabled and uses Alt+Shift+Return for a second foot.
RUN printf '%s\n' 'https://dl-cdn.alpinelinux.org/alpine/v3.24/community' >> /etc/apk/repositories && \
    apk add --no-cache alpine-sdk build-base libinput-dev pkgconf wayland-dev \
        wayland-protocols libxkbcommon-dev wlroots0.19-dev wget
RUN set -eux; \
    mkdir -p /work/src; \
    wget -O /work/dwl-0.8.tar.gz \
        https://codeberg.org/dwl/dwl/archive/v0.8.tar.gz; \
    printf '%s  %s\n' \
        3080087e7f613bf6a350934231fd9ed478d04cd2a2f30da8a96cdf2066f59412 \
        /work/dwl-0.8.tar.gz | sha256sum -c -; \
    tar -xzf /work/dwl-0.8.tar.gz -C /work/src; \
    cd /work/src/dwl; \
    make; \
    install -m 0755 dwl /work/dwl

FROM alpine:3.24.1 AS rootfs

RUN printf '%s\n' 'https://dl-cdn.alpinelinux.org/alpine/v3.24/community' >> /etc/apk/repositories && \
    apk add --no-cache apk-tools-static binutils lddtree kmod tar gzip
COPY --from=upstream-dwl-build /work/dwl /work/dwl
COPY rootfs-packages.txt /work/rootfs-packages.txt
COPY rootfs/fetch.sh /work/fetch.sh
COPY rootfs/configure.sh /work/configure-rootfs.sh
COPY rootfs/patch-initramfs.sh /work/patch-initramfs.sh
COPY rootfs/home-login /work/home-login
COPY rootfs/home-session /work/home-session
COPY rootfs/home-runtime.initd /work/home-runtime.initd
COPY rootfs/foot.ini /work/foot.ini
COPY build/build-rootfs.sh /work/build-rootfs.sh
RUN chmod +x /work/configure-rootfs.sh /work/patch-initramfs.sh /work/build-rootfs.sh \
        /work/home-login /work/home-session /work/home-runtime.initd && \
    /work/build-rootfs.sh

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
        -end && \
    bytes=$(stat -c '%s' /work/out/home-installer-patched.iso) && \
    hash=$(sha256sum /work/out/home-installer-patched.iso | awk '{print $1}') && \
    awk -v bytes="$bytes" -v hash="$hash" '$1 == "iso" && $2 == "bytes:" {print "iso bytes: " bytes; next} $1 == "iso" && $2 == "sha256:" {print "iso sha256: " hash; next} {print}' /work/out/iso-metadata.txt > /work/out/iso-metadata.final && \
    mv /work/out/iso-metadata.final /work/out/iso-metadata.txt

FROM scratch AS artifact
COPY --from=patched /work/out/home-installer-patched.iso /home-installer.iso
COPY --from=rootfs /work/out/rootfs-metadata.txt /rootfs-metadata.txt
COPY --from=patched /work/out/iso-metadata.txt /iso-metadata.txt
