# Base image for both the builder and the runtime stages. Override at build
# time with --build-arg MARINER_IMAGE=... to track a different Azure Linux
# base (e.g. test a new image revision before promoting it).
ARG MARINER_IMAGE=mcr.microsoft.com/azurelinux/base/core:3.0

# Create a builder image with the compilers, etc. needed
FROM ${MARINER_IMAGE} AS build-env

# Install all the required packages for building. This list is probably
# longer than necessary.
RUN echo "== Install Git/CA certificates ==" && \
    tdnf install -y \
        git \
        ca-certificates

RUN echo "== Install Core dependencies ==" && \
    tdnf install -y \
        alsa-lib \
        alsa-lib-devel  \
        autoconf  \
        automake  \
        binutils  \
        bison  \
        build-essential  \
        cairo \
        cairo-devel \
        clang  \
        clang-devel  \
        dbus  \
        dbus-devel  \
        dbus-glib  \
        dbus-glib-devel  \
        diffutils  \
        elfutils-devel  \
        file-libs  \
        flex  \
        fontconfig-devel  \
        gawk  \
        gcc  \
        gettext  \
        glibc-devel  \
        glib-schemas \
        gobject-introspection  \
        gobject-introspection-devel  \
        harfbuzz  \
        harfbuzz-devel  \
        kernel-headers  \
        intltool \
        libatomic_ops  \
        libcap-devel  \
        libffi  \
        libffi-devel  \
        libgudev  \
        libgudev-devel  \
        libjpeg-turbo  \
        libjpeg-turbo-devel  \
        libltdl  \
        libltdl-devel  \
        libpng-devel  \
        librsvg2-devel \
        libtiff  \
        libtiff-devel  \
        libusb  \
        libusb-devel  \
        libwebp  \
        libwebp-devel  \
        libxml2 \
        libxml2-devel  \
        make  \
        meson  \
        newt  \
        nss  \
        nss-libs  \
        openldap  \
        openssl-devel  \
        pam-devel  \
        pango  \
        pango-devel  \
        patch  \
        perl-XML-Parser \
        polkit-devel  \
        python3-devel \
        python3-mako  \
        python3-markupsafe \
        sed \
        sqlite-devel \
        systemd-devel  \
        tar \
        unzip  \
        vala  \
        vala-devel  \
        vala-tools  \
        zlib-devel

RUN echo "== Install UI dependencies ==" && \
    tdnf    install -y \
            libdrm-devel \
            libepoxy-devel \
            libevdev \
            libevdev-devel \
            libinput \
            libinput-devel \
            libpciaccess-devel \
            libSM-devel \
            libsndfile \
            libsndfile-devel \
            libXcursor \
            libXcursor-devel \
            libXdamage-devel \
            libXfont2-devel \
            libXi \
            libXi-devel \
            libxkbcommon-devel \
            libxkbfile-devel \
            libXrandr-devel \
            libxshmfence-devel \
            libXtst \
            libXtst-devel \
            libXxf86vm-devel \
            wayland-devel \
            wayland-protocols-devel \
            xkbcomp \
            xkeyboard-config \
            xorg-x11-server-Xwayland-devel \
            xorg-x11-util-macros

# Create an image with the system distro's runtime pieces
FROM build-env AS dev

ARG WSLG_VERSION="<current>"
ARG WSLG_COMMIT="<unknown>"
ARG WSLG_ARCH="x86_64"
ARG DIRECTX_HEADERS_VERSION="<unknown>"
ARG PULSEAUDIO_COMMIT="<unknown>"
ARG SYSTEMDISTRO_DEBUG_BUILD

# Fail fast if any required --build-arg is missing or still holds a
# placeholder value. We have to validate up-front because the values
# flow straight into /etc/versions.txt for supportability; a build
# that silently produced "wslg: <unknown>" in the VHD was previously
# a real footgun (CI misconfig surfacing 30 minutes into the build
# instead of in the first step).
#
# WSLG_ARCH is intentionally excluded from this loop -- it has a real
# default ("x86_64") and is never a placeholder value.
#
# The reject list is "" / "<unknown>" / "<current>" / "unknown":
#   - the angle-bracketed forms are the ARG defaults declared above and
#     mean "caller forgot --build-arg";
#   - bare "unknown" is reserved for "something went wrong" and is
#     deliberately NOT what build-and-export.sh falls back to (it uses
#     "dev" instead, which this loop permits).
RUN set -e; \
    for kv in "WSLG_VERSION=${WSLG_VERSION}" \
              "WSLG_COMMIT=${WSLG_COMMIT}" \
              "DIRECTX_HEADERS_VERSION=${DIRECTX_HEADERS_VERSION}" \
              "PULSEAUDIO_COMMIT=${PULSEAUDIO_COMMIT}"; do \
        name=${kv%%=*}; val=${kv#*=}; \
        case "$val" in \
            ""|"<unknown>"|"<current>"|"unknown") \
                echo "ERROR: required --build-arg $name is unset or a placeholder ('$val')." >&2; \
                echo "       Pass an explicit value, or run ./build-and-export.sh from the wslg/" >&2; \
                echo "       checkout (see CONTRIBUTING.md for the manual docker build recipe)." >&2; \
                exit 1 ;; \
        esac; \
    done; \
    echo "All 4 required --build-arg values present."

WORKDIR /work
RUN printf 'WSLg: %s\nArchitecture: %s\nBuilt: %s\nOS: %s\n\n' \
        "${WSLG_VERSION}" \
        "${WSLG_ARCH}" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$(. /etc/os-release && echo "${PRETTY_NAME}")" \
        > /work/versions.txt && \
    printf '%-16s %s\n' \
        'wslg:'            "${WSLG_COMMIT}" \
        'DirectX-Headers:' "${DIRECTX_HEADERS_VERSION}" \
        'pulseaudio:'      "${PULSEAUDIO_COMMIT}" \
        >> /work/versions.txt

#
# Build runtime dependencies.
#

ENV BUILDTYPE=${SYSTEMDISTRO_DEBUG_BUILD:+debug}
ENV BUILDTYPE=${BUILDTYPE:-debugoptimized}

ENV BUILDTYPE_NODEBUGSTRIP=${SYSTEMDISTRO_DEBUG_BUILD:+debug}
ENV BUILDTYPE_NODEBUGSTRIP=${BUILDTYPE_NODEBUGSTRIP:-release}

RUN echo "== System distro build types ==" && \
    echo "    BUILDTYPE:              ${BUILDTYPE}" && \
    echo "    BUILDTYPE_NODEBUGSTRIP: ${BUILDTYPE_NODEBUGSTRIP}"

ENV DESTDIR=/work/build
ENV PREFIX=/usr
ENV PKG_CONFIG_PATH=${DESTDIR}${PREFIX}/lib/pkgconfig:${DESTDIR}${PREFIX}/lib/${WSLG_ARCH}-linux-gnu/pkgconfig:${DESTDIR}${PREFIX}/share/pkgconfig
ENV C_INCLUDE_PATH=${DESTDIR}${PREFIX}/include/wsl/stubs:${DESTDIR}${PREFIX}/include
ENV CPLUS_INCLUDE_PATH=${C_INCLUDE_PATH}
ENV LIBRARY_PATH=${DESTDIR}${PREFIX}/lib
ENV LD_LIBRARY_PATH=${LIBRARY_PATH}
ENV CC=/usr/bin/gcc
ENV CXX=/usr/bin/g++

# Setup DebugInfo folder
COPY debuginfo /work/debuginfo
RUN chmod +x /work/debuginfo/*.sh

# Build DirectX-Headers
COPY vendor/DirectX-Headers-1.0 /work/vendor/DirectX-Headers-1.0
WORKDIR /work/vendor/DirectX-Headers-1.0
RUN /usr/bin/meson --prefix=${PREFIX} build \
        --buildtype=${BUILDTYPE_NODEBUGSTRIP} \
        -Dbuild-test=false && \
    ninja -C build -j8 install

# Build PulseAudio
COPY vendor/pulseaudio /work/vendor/pulseaudio
WORKDIR /work/vendor/pulseaudio
RUN /usr/bin/meson --prefix=${PREFIX} build \
        --buildtype=${BUILDTYPE_NODEBUGSTRIP} \
        -Ddatabase=simple \
        -Ddoxygen=false \
        -Dgsettings=disabled \
        -Dtests=false && \
    ninja -C build -j8 install

# Build WSLGd Daemon
ENV CC=/usr/bin/clang
ENV CXX=/usr/bin/clang++

COPY WSLGd /work/WSLGd
WORKDIR /work/WSLGd
RUN /usr/bin/meson --prefix=${PREFIX} build \
        --buildtype=${BUILDTYPE} && \
    ninja -C build -j8 install

RUN /work/debuginfo/strip_debuginfo.sh "WSLGd" "/work/debuginfo/WSLGd.list"

# Gather debuginfo to a tar file. strip_debuginfo.sh above already
# populated /work/build/debuginfo with per-binary .debug files; this
# is a no-op for SYSTEMDISTRO_DEBUG_BUILD builds because nothing was
# split out in the first place.
RUN if [ -z "$SYSTEMDISTRO_DEBUG_BUILD" ] ; then \
        echo "== Compress debug info: /work/debuginfo/system-debuginfo.tar.gz ==" && \
        tar -C /work/build/debuginfo -czf /work/debuginfo/system-debuginfo.tar.gz ./ ; \
    fi

########################################################################
########################################################################

## Create the distro image with just what's needed at runtime

FROM ${MARINER_IMAGE} AS runtime

RUN echo "== Install Core/UI Runtime Dependencies ==" && \
    tdnf    install -y \
            busybox \
            ca-certificates \
            cairo \
            chrony \
            containerd2 \
            containernetworking-plugins \
            runc \
            dbus \
            dbus-glib \
            dhcpcd \
            docker-buildx \
            docker-cli \
            e2fsprogs \
            freefont \
            gzip \
            icu \
            iptables \
            kmod \
            libinput \
            libjpeg-turbo \
            libltdl \
            libpng \
            librsvg2 \
            libsndfile \
            libwayland-client \
            libwayland-server \
            libwayland-cursor \
            libwebp \
            libXcursor \
            libxkbcommon \
            libXrandr \
            iproute \
            moby-engine \
            nftables \
            pango \
            procps-ng \
            rpm \
            sed \
            systemd-libs \
            tar \
            tzdata \
            util-linux \
            xcursor-themes \
            xorg-x11-server-Xwayland \
            xorg-x11-server-utils

# Install busybox utilities
RUN /sbin/busybox --install -s

# Remove unnecessary packages and files to reduce image size
ARG SYSTEMDISTRO_DEBUG_BUILD
RUN if [ -z "$SYSTEMDISTRO_DEBUG_BUILD" ] ; then \
        echo "== Removing unnecessary packages ==" && \
        # Remove build tools and packages not needed at runtime \
        rpm -e --nodeps \
            cracklib-dicts \
            gcc \
            gcc-c++ \
            libpkgconf \
            llvm \
            perl \
            pkgconf \
            pkgconf-m4 \
            pkgconf-pkg-config \
            python3 \
            python3-libs && \
        # Remove all perl subpackages \
        rpm -e --nodeps $(rpm -qa | grep -- '^perl-') && \
        # Remove all -devel packages \
        rpm -e --nodeps $(rpm -qa | grep -- '-devel') && \
        # Remove systemd components (except systemd-libs which is needed by WSLGd) \
        rpm -e --nodeps $(rpm -qa | grep -- '^systemd-' | grep -v systemd-libs) && \
        # Remove orphaned packages \
        tdnf autoremove -y && \
        echo "== Removing unnecessary files ==" && \
        # Remove docs, man pages, locales, gtk-doc \
        rm -rf /usr/share/man /usr/share/info /usr/share/locale /usr/share/gtk-doc && \
        find /usr/share/doc -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + && \
        # Remove hardware database (not needed in WSL) \
        rm -rf /usr/share/hwdata/* && \
        # Remove temporary files, logs, caches, and systemd catalog \
        rm -rf /tmp/* /var/tmp/* /var/log/* /var/cache/* /usr/lib/systemd/catalog/*; \
    else \
        echo "== Install development aid packages ==" && \
        tdnf install -y \
             gdb \
             azurelinux-repos-debug \
             nano \
             vim \
             wayland-debuginfo \
             xorg-x11-server-debuginfo; \
    fi

# Clear the tdnf cache to make the image smaller
RUN tdnf clean all

# Create wslg user.
RUN useradd -u 1000 --create-home wslg && \
    mkdir /home/wslg/.config && \
    chown wslg /home/wslg/.config

# Copy config files.
COPY config/wsl.conf /etc/wsl.conf
COPY config/local.conf /etc/fonts/local.conf

# Copy default icon file.
COPY resources/linux.png /usr/share/icons/wsl/linux.png

# Copy the built artifacts from the build stage.
COPY --from=dev /work/build/usr/ /usr/
COPY --from=dev /work/build/etc/ /etc/

# Append WSLg setttings to pulseaudio.
COPY config/default_wslg.pa /etc/pulse/default_wslg.pa
RUN cat /etc/pulse/default_wslg.pa >> /etc/pulse/default.pa
RUN rm /etc/pulse/default_wslg.pa

# Copy the licensing information for PulseAudio
COPY --from=dev /work/vendor/pulseaudio/GPL \
                /work/vendor/pulseaudio/LGPL \
                /work/vendor/pulseaudio/LICENSE \
                /work/vendor/pulseaudio/NEWS \
                /work/vendor/pulseaudio/README /usr/share/doc/pulseaudio/

COPY --from=dev /work/versions.txt /etc/versions.txt

CMD /usr/bin/WSLGd
