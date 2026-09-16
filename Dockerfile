FROM alpine:3.24.1 AS upstream-dwl-build

# Alpine 3.24.1 does not ship a dwl package.  Build the pinned upstream
# release with its stock configuration in a build-only stage; the compiler,
# headers and source archive never enter the target rootfs.  The upstream
# default keeps XWayland disabled; the two small build-time substitutions
# below make the requested Ctrl+Return terminal binding and remove the
# stock example binding to the intentionally absent wmenu-run.
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
    sed -i \
        -e '/static const char \*menucmd\[\] = { "wmenu-run", NULL };/d' \
        -e '/{ MODKEY,                    XKB_KEY_p,           spawn,            {.v = menucmd} },/d' \
        -e 's/{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_Return,      spawn,            {.v = termcmd} },/{ WLR_MODIFIER_CTRL,          XKB_KEY_Return,      spawn,            {.v = termcmd} },/' \
        config.def.h; \
    if grep -Fq 'wmenu-run' config.def.h || ! grep -Fq '{ WLR_MODIFIER_CTRL,          XKB_KEY_Return,      spawn,            {.v = termcmd} },' config.def.h; then \
        echo 'upstream dwl configuration substitutions were not applied' >&2; \
        exit 1; \
    fi; \
    make; \
    install -m 0755 dwl /work/dwl

FROM alpine:3.24.1 AS assets

# The ISO carries only the installer assets. The target package closure is
# resolved by apk after the live network preflight, so the target filesystem
# never enters the image build or the ISO.
COPY --from=upstream-dwl-build /work/dwl /work/assets/dwl
COPY rootfs-packages.txt /work/assets/rootfs-packages.txt
COPY rootfs/repositories /work/assets/repositories
COPY rootfs/fetch.sh /work/assets/fetch.sh
COPY rootfs/configure.sh /work/assets/configure.sh
COPY rootfs/home-login /work/assets/home-login
COPY rootfs/home-session /work/assets/home-session
COPY rootfs/home-runtime.initd /work/assets/home-runtime.initd
COPY rootfs/foot.ini /work/assets/foot.ini
RUN chmod +x /work/assets/dwl /work/assets/configure.sh \
        /work/assets/fetch.sh /work/assets/home-login \
        /work/assets/home-session /work/assets/home-runtime.initd

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

COPY --from=assets /work/assets /work/assets
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
COPY --from=patched /work/out/iso-metadata.txt /iso-metadata.txt
