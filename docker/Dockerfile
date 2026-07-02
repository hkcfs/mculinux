# MCUlinux Docker Builder
# Based on ESP32-S3 Linux build system
# https://github.com/jcmvbkbc/esp32-linux-build
# https://github.com/hpsaturn/esp32s3-linux
#
# Build from project root:
#   docker build -f docker/Dockerfile --build-arg DOCKER_USER=$USER --build-arg DOCKER_USERID=$UID -t mculinux-builder .

FROM ubuntu:22.04

ARG DOCKER_USER=builder
ARG DOCKER_USERID=1000

# Install build dependencies
RUN apt-get update && apt-get -y install \
    gperf bison flex texinfo help2man gawk libtool-bin \
    git unzip ncurses-dev rsync zlib1g zlib1g-dev xz-utils \
    cmake wget bzip2 g++ python3 python3-dev python3-pip \
    python3.10-venv cpio bc virtualenv libusb-1.0-0 \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/python3 /usr/bin/python

WORKDIR /app

# Install autoconf 2.71 (required by Buildroot)
RUN wget -q https://ftp.gnu.org/gnu/autoconf/autoconf-2.71.tar.xz && \
    tar -xf autoconf-2.71.tar.xz && \
    cd autoconf-2.71 && \
    ./configure --prefix=$(pwd)/root && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf autoconf-2.71 autoconf-2.71.tar.xz

ENV PATH="/app/autoconf-2.71/root/bin:${PATH}"

# Create non-root user
RUN chmod a+rwx /app && \
    useradd -d /app/build -u ${DOCKER_USERID} ${DOCKER_USER} && \
    mkdir -p /app/build && \
    chown ${DOCKER_USER}:${DOCKER_USER} /app/build && \
    usermod -a -G dialout ${DOCKER_USER}

USER ${DOCKER_USER}

# Clone build scripts
RUN git clone --depth 1 https://github.com/jcmvbkbc/esp32-linux-build.git /app/build-scripts

WORKDIR /app/build
CMD ["./build-all.sh"]
