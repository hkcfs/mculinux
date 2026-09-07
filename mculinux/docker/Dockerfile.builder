# MCUlinux fat builder image (ghcr.io/hkcfs/mculinux/builder)
# Toolchain + kernel/busybox sources + QEMU pre-baked, so CI jobs never
# download or compile the same thing twice.
#
# Build from repo root:
#   docker build -f mculinux/docker/Dockerfile.builder -t mculinux-builder .
# Normally built by .github/workflows/docker.yml (push + weekly refresh).

ARG UBUNTU_TAG=24.04
FROM ubuntu:${UBUNTU_TAG}

# Bumpable source versions (keep in sync with Makefile KERNEL_VERSION).
ARG TOOLCHAIN_URL=https://github.com/hkcfs/mculinux/releases/download/toolchain/xtensa-esp32s3-linux-muslfdpic.tar.xz
ARG TOOLCHAIN_DIR=/opt/crosstool-ng/xtensa-esp32s3-linux-muslfdpic
ARG KERNEL_VERSIONS="7.1.3 7.2.3"
ARG BUSYBOX_VERSION=1.38.0
ARG QEMU_TARBALL_URL=https://github.com/espressif/qemu/releases/download/esp-develop-9.2.2-20250228/qemu-xtensa-softmmu-esp_develop_9.2.2_20250228-x86_64-linux-gnu.tar.xz

# Build dependencies (crosstool-NG/Buildroot/kernel) + QEMU runtime libs.
RUN apt-get update && apt-get -y install --no-install-recommends \
    gperf bison flex texinfo help2man gawk libtool-bin \
    git unzip rsync zlib1g zlib1g-dev xz-utils curl ca-certificates \
    cmake wget bzip2 g++ gcc make file python3 python3-dev python3-pip \
    python3-venv cpio bc libncurses-dev libssl-dev libexpat1-dev \
    libusb-1.0-0 libgcrypt20 libglib2.0-0 libpixman-1-0 libsdl2-2.0-0 libslirp0 \
    fakeroot libfakeroot \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/python3 /usr/bin/python \
    && ln -sf /usr/lib/x86_64-linux-gnu/fakeroot/libfakeroot-sysv.so /usr/lib/x86_64-linux-gnu/libfakeroot.so

# Autoconf 2.71 (required by Buildroot; distro ships older).
RUN wget -q https://ftp.gnu.org/gnu/autoconf/autoconf-2.71.tar.xz && \
    tar -xf autoconf-2.71.tar.xz && \
    cd autoconf-2.71 && \
    ./configure --prefix=/opt/autoconf-2.71 && \
    make -j"$(nproc)" && make install && \
    cd .. && rm -rf autoconf-2.71 autoconf-2.71.tar.xz
ENV PATH="/opt/autoconf-2.71/bin:${PATH}"

# Prebuilt musl cross-toolchain (~45 min to build; never again in CI).
RUN mkdir -p /opt && \
    wget -q "$TOOLCHAIN_URL" -O /tmp/toolchain.tar.xz && \
    tar -xf /tmp/toolchain.tar.xz -C /opt/ && \
    rm -f /tmp/toolchain.tar.xz && \
    test -x "$TOOLCHAIN_DIR/bin/xtensa-esp32s3-linux-muslfdpic-gcc"
ENV PATH="${TOOLCHAIN_DIR}/bin:${PATH}"

# Kernel + busybox sources, compressed (jobs extract what they need).
RUN mkdir -p /opt/src && \
    for v in $KERNEL_VERSIONS; do \
      wget -q "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-${v}.tar.xz" \
        -O "/opt/src/linux-${v}.tar.xz"; \
    done && \
    wget -q "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2" \
      -O "/opt/src/busybox-${BUSYBOX_VERSION}.tar.bz2" && \
    ls -lh /opt/src/

# Espressif QEMU (esp32s3 machine). test-qemu.sh uses $QEMU first.
RUN mkdir -p /tmp/qextract /opt/qemu && \
    wget -q "$QEMU_TARBALL_URL" -O /tmp/qemu.tar.xz && \
    tar -xf /tmp/qemu.tar.xz -C /tmp/qextract && \
    (test -d /tmp/qextract/qemu && cp -r /tmp/qextract/qemu/* /opt/qemu/ || \
     cp -r /tmp/qextract/* /opt/qemu/) && \
    rm -rf /tmp/qextract /tmp/qemu.tar.xz && \
    test -x /opt/qemu/bin/qemu-system-xtensa
ENV QEMU=/opt/qemu/bin/qemu-system-xtensa

# Non-root build user (matches local docker-compose flow).
ARG DOCKER_USER=builder
ARG DOCKER_USERID=1000
RUN useradd -m -u "${DOCKER_USERID}" "${DOCKER_USER}" && \
    usermod -a -G dialout "${DOCKER_USER}" && \
    mkdir -p /work && chown "${DOCKER_USER}:${DOCKER_USER}" /work
USER ${DOCKER_USER}
WORKDIR /work
CMD ["bash"]
