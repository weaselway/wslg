# Base image for both the builder and the runtime stages. Override at build
# time with --build-arg MARINER_IMAGE=... to track a different Azure Linux
# base (e.g. test a new image revision before promoting it).
ARG MARINER_IMAGE=mcr.microsoft.com/azurelinux/base/core:3.0

# Create a builder image with the compilers, etc. needed
FROM ${MARINER_IMAGE} AS build-env

# Install the packages needed to build WSLGd. The system distro no longer
# builds a compositor (mutter runs in the user distro) or PulseAudio (the RDP
# audio bridge talks directly to PipeWire in the user distro instead), so
# nothing here pulls in a graphics/X11 stack or an audio server.
RUN echo "== Install build dependencies ==" && \
    tdnf install -y \
        binutils \
        build-essential \
        ca-certificates \
        clang \
        dbus-devel \
        diffutils \
        file-libs \
        gcc \
        gettext \
        git \
        glibc-devel \
        libcap-devel \
        libtool \
        m4 \
        make \
        meson \
        sed \
        tar

# Create an image with the system distro's runtime pieces
FROM build-env AS dev

ARG WSLG_VERSION="<current>"
ARG WSLG_COMMIT="<unknown>"
ARG WSLG_ARCH="x86_64"
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
              "WSLG_COMMIT=${WSLG_COMMIT}"; do \
        name=${kv%%=*}; val=${kv#*=}; \
        case "$val" in \
            ""|"<unknown>"|"<current>"|"unknown") \
                echo "ERROR: required --build-arg $name is unset or a placeholder ('$val')." >&2; \
                echo "       Pass an explicit value, or run ./build-and-export.sh from the wslg/" >&2; \
                echo "       checkout (see CONTRIBUTING.md for the manual docker build recipe)." >&2; \
                exit 1 ;; \
        esac; \
    done; \
    echo "All 2 required --build-arg values present."

WORKDIR /work
RUN printf 'WSLg: %s\nArchitecture: %s\nBuilt: %s\nOS: %s\n\n' \
        "${WSLG_VERSION}" \
        "${WSLG_ARCH}" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$(. /etc/os-release && echo "${PRETTY_NAME}")" \
        > /work/versions.txt && \
    printf '%-16s %s\n' \
        'wslg:'            "${WSLG_COMMIT}" \
        >> /work/versions.txt

#
# Build runtime dependencies.
#

ENV BUILDTYPE=${SYSTEMDISTRO_DEBUG_BUILD:+debug}
ENV BUILDTYPE=${BUILDTYPE:-debugoptimized}

RUN echo "== System distro build types ==" && \
    echo "    BUILDTYPE:              ${BUILDTYPE}"

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

# ensure /etc/ exists
RUN mkdir -p /work/build/etc/

########################################################################
########################################################################

## Create the distro image with just what's needed at runtime

FROM ${MARINER_IMAGE} AS runtime

# Runtime dependencies. The system distro runs WSLGd and dbus only: the
# compositor, its X server, the RDP client and the audio server (PipeWire) all
# live outside this image, so no graphics, font, X11 or audio packages are
# installed.
#
# N.B. The Docker/containerd stack upstream installs here (moby-engine,
# containerd2, docker-cli, docker-buildx, containernetworking-plugins, runc,
# iptables) is deliberately left out: nothing in this image starts it -- there
# is no systemd and WSLGd only launches dbus -- and it accounted for ~370MB of
# the image.
RUN echo "== Install Runtime Dependencies ==" && \
    tdnf    install -y \
            busybox \
            ca-certificates \
            chrony \
            dbus \
            dhcpcd \
            e2fsprogs \
            gzip \
            kmod \
            iproute \
            nftables \
            procps-ng \
            rpm \
            sed \
            systemd-libs \
            tar \
            tzdata \
            util-linux

# Install busybox utilities
RUN /sbin/busybox --install -s

# Remove unnecessary packages and files to reduce image size
ARG SYSTEMDISTRO_DEBUG_BUILD
RUN if [ -z "$SYSTEMDISTRO_DEBUG_BUILD" ] ; then \
        echo "== Removing unnecessary packages ==" && \
        # Erase only what is actually installed. Most of the list below used to \
        # arrive as a dependency of the graphics/X11 stack; now that none of \
        # that is installed, a plain `rpm -e` would fail on the missing ones \
        # (and on an empty argument list from the greps further down). \
        erase() { \
            set -- $(for p in "$@"; do rpm -q "$p" > /dev/null 2>&1 && echo "$p"; done); \
            if [ $# -gt 0 ]; then rpm -e --nodeps "$@"; fi; \
        }; \
        # Remove build tools and packages not needed at runtime \
        erase \
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
        erase $(rpm -qa | grep -- '^perl-') && \
        # Remove all -devel packages \
        erase $(rpm -qa | grep -- '-devel') && \
        # Remove systemd components (except systemd-libs which is needed by WSLGd) \
        erase $(rpm -qa | grep -- '^systemd-' | grep -v systemd-libs) && \
        # Remove orphaned packages \
        tdnf autoremove -y && \
        # Orphans autoremove leaves behind: ICU has no consumer left in the \
        # image (only its own tools link it) and the X keyboard layouts went \
        # unused when the X server left. \
        erase icu xkeyboard-config && \
        echo "== Removing unnecessary files ==" && \
        # Remove docs, man pages, locales, gtk-doc \
        rm -rf /usr/share/man /usr/share/info /usr/share/locale /usr/share/gtk-doc && \
        find /usr/share/doc -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + && \
        # Remove hardware database (not needed in WSL) \
        rm -rf /usr/share/hwdata/* && \
        # Remove static libraries, which nothing at runtime can use \
        find /usr/lib /usr/lib64 -name '*.a' -type f -delete && \
        # Remove temporary files, logs, caches, and systemd catalog \
        rm -rf /tmp/* /var/tmp/* /var/log/* /var/cache/* /usr/lib/systemd/catalog/*; \
    else \
        echo "== Install development aid packages ==" && \
        tdnf install -y \
             gdb \
             azurelinux-repos-debug \
             nano \
             vim; \
    fi

# Clear the tdnf cache to make the image smaller
RUN tdnf clean all

# Create wslg user.
RUN useradd -u 1000 --create-home wslg && \
    mkdir /home/wslg/.config && \
    chown wslg /home/wslg/.config

# Copy config files.
COPY config/wsl.conf /etc/wsl.conf

# Copy the built artifacts from the build stage.
COPY --from=dev /work/build/usr/ /usr/
COPY --from=dev /work/build/etc/ /etc/

COPY --from=dev /work/versions.txt /etc/versions.txt

CMD /usr/bin/WSLGd
