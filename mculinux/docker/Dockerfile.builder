# MCUlinux fat builder image (ghcr.io/hkcfs/mculinux/builder)
# Toolchain (release tarball) + kernel/busybox sources + QEMU pre-baked,
# so CI jobs never download or compile the same thing twice.
# (A FROM-toolchain-image variant was evaluated and dropped: a manually
# pushed base stays private+unlinked, and CI's GITHUB_TOKEN gets 403
# pulling it. The public release tarball needs no auth.)
#
# Build from repo root:
#   docker build -f mculinux/docker/Dockerfile.builder -t mculinux-builder .
# Normally built by .github/workflows/docker.yml (push + weekly refresh).

ARG UBUNTU_TAG=latest
FROM ubuntu:${UBUNTU_TAG}

# /bin/sh is dash here; the fetch() fallback below needs bash substitution.
SHELL ["/bin/bash", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

# Bumpable source versions (kernel is always latest-stable, resolved below;
# busybox is always latest-stable, resolved via git tags below).
ARG TOOLCHAIN_URL=https://github.com/hkcfs/mculinux/releases/download/toolchain/xtensa-esp32s3-linux-muslfdpic.tar.xz
ARG TOOLCHAIN_DIR=/opt/crosstool-ng/xtensa-esp32s3-linux-muslfdpic
ARG QEMU_TARBALL_URL=https://github.com/espressif/qemu/releases/download/esp-develop-9.2.2-20260417/qemu-xtensa-softmmu-esp_develop_9.2.2_20260417-x86_64-linux-gnu.tar.xz

# Build dependencies (toolchain/kernel/busybox) + QEMU runtime libs.
RUN apt-get update && apt-get -y install --no-install-recommends \
    gperf bison flex texinfo help2man gawk libtool-bin \
    git unzip zip rsync zlib1g zlib1g-dev xz-utils curl ca-certificates \
    cmake wget bzip2 g++ gcc make file patch python3 python3-dev python3-pip \
    python3-venv cpio bc libncurses-dev libssl-dev libexpat1-dev \
    libusb-1.0-0 libgcrypt20 libglib2.0-0 libpixman-1-0 libsdl2-2.0-0 libslirp0 \
    fakeroot libfakeroot erofs-utils mtd-utils \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/python3 /usr/bin/python \
    && ln -sf /usr/lib/x86_64-linux-gnu/fakeroot/libfakeroot-sysv.so /usr/lib/x86_64-linux-gnu/libfakeroot.so

# Autoconf 2.71 (kernel/busybox configure scripts need it; distro ships older).
RUN wget -q https://ftp.gnu.org/gnu/autoconf/autoconf-2.71.tar.xz && \
    tar -xf autoconf-2.71.tar.xz && \
    cd autoconf-2.71 && \
    ./configure --prefix=/opt/autoconf-2.71 && \
    make -j"$(nproc)" && make install && \
    cd .. && rm -rf autoconf-2.71 autoconf-2.71.tar.xz
ENV PATH="/opt/autoconf-2.71/bin:${PATH}"

# Prebuilt musl cross-toolchain (~45 min to build; never again in CI).
# Release asset is public (world-readable tarball), so no auth needed here.
RUN mkdir -p /opt && \
    wget -q "$TOOLCHAIN_URL" -O /tmp/toolchain.tar.xz && \
    tar -xf /tmp/toolchain.tar.xz -C /opt/ && \
    rm -f /tmp/toolchain.tar.xz && \
    test -x "$TOOLCHAIN_DIR/bin/xtensa-esp32s3-linux-muslfdpic-gcc"
ENV PATH="${TOOLCHAIN_DIR}/bin:${PATH}"

# Kernel + busybox sources, compressed (jobs extract what they need).
# Always the latest stable kernel — automation policy: build newest, fail
# loudly if our patches stop applying, never pin a "known good" version.
# Retries + edge mirror: CI runners occasionally drop long downloads.
RUN mkdir -p /opt/src && \
    LATEST_STABLE=$(curl -s --max-time 30 https://kernel.org | grep -A 1 'stable:' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1) && \
    test -n "$LATEST_STABLE" && \
    echo "Prefetching linux-$LATEST_STABLE..." && \
    fetch() { \
      url="$1"; out="$2"; \
      wget -q --tries=3 --timeout=120 "$url" -O "$out" || \
      wget -q --tries=5 --timeout=120 "${url/cdn.kernel.org/mirrors.edge.kernel.org}" -O "$out"; \
    } && \
    fetch "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-${LATEST_STABLE}.tar.xz" \
      "/opt/src/linux-${LATEST_STABLE}.tar.xz" && \
    ls -lh /opt/src/ && \
    test "$(ls /opt/src/linux-*.tar.xz 2>/dev/null | wc -l)" -ge 1

# Busybox source, always latest stable: shallow git clone of the newest tag
# (max over all remotes — some mirrors go stale; tarballs are unreliable).
# Best-effort cache only: CI re-resolves at job time. Warn, don't fail —
# a blip here must not break the whole image.
RUN BBTAGS="$(git ls-remote --tags git://git.busybox.net/busybox 2>/dev/null; \
      git ls-remote --tags https://git.busybox.net/busybox 2>/dev/null; \
      git ls-remote --tags https://github.com/mirror/busybox 2>/dev/null)" && \
    BBTAG="$(echo "$BBTAGS" | grep -oE 'refs/tags/[0-9]+_[0-9]+_[0-9]+$' \
      | sed 's|refs/tags/||' | sort -uV | tail -1)" && \
    if [ -n "$BBTAG" ]; then \
      BBVER="$(echo "$BBTAG" | tr '_' '.')" && \
      echo "$BBVER" > /opt/src/busybox.version && \
      (git clone --depth 1 --branch "$BBTAG" git://git.busybox.net/busybox \
        "/opt/src/busybox-$BBVER" 2>/dev/null || \
       git clone --depth 1 --branch "$BBTAG" https://github.com/mirror/busybox \
        "/opt/src/busybox-$BBVER" 2>/dev/null || \
       echo "WARN: busybox prefetch clone failed") && \
      ls -d /opt/src/busybox-* 2>/dev/null || echo "WARN: no busybox source cached"; \
    else \
      echo "WARN: could not resolve latest busybox tag, skipping prefetch"; \
    fi

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
# Numeric USER: works whether 1000 is fresh or pre-existing (e.g. ubuntu user).
ARG DOCKER_USER=builder
ARG DOCKER_USERID=1000
RUN (useradd -m -u "${DOCKER_USERID}" "${DOCKER_USER}" 2>/dev/null || \
     echo "UID ${DOCKER_USERID} exists, reusing $(id -nu "${DOCKER_USERID}")") && \
    usermod -a -G dialout "$(id -nu "${DOCKER_USERID}")" && \
    mkdir -p /work /app/build && \
    chown "$(id -nu "${DOCKER_USERID}"):$(id -ng "${DOCKER_USERID}")" /work /app/build
USER ${DOCKER_USERID}
WORKDIR /work
CMD ["bash"]
