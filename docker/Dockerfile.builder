# MCUlinux Builder Dockerfile
# This Dockerfile creates the build environment for cross-compiling packages

FROM alpine:3.19

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    cmake \
    git \
    python3 \
    py3-pip \
    wget \
    curl \
    unzip \
    flex \
    bison \
    gperf \
    ninja-build \
    ccache \
    libuv-dev \
    openssl-dev \
    linux-headers

# Install ESP-IDF toolchain
RUN mkdir -p /opt/esp-idf && \
    cd /opt && \
    git clone --depth 1 --branch v5.2.2 --recursive --shallow-submodules \
    https://github.com/espressif/esp-idf.git && \
    cd esp-idf && \
    ./install.sh xtensa-esp32s3 && \
    rm -rf .git

# Set up environment
ENV IDF_PATH=/opt/esp-idf
ENV PATH="${IDF_PATH}/tools:${PATH}"

# Source ESP-IDF environment
RUN . "${IDF_PATH}/export.sh"

# Create build directories
RUN mkdir -p /packages /output /src

# Copy build scripts
COPY mculinux-packages/scripts/ /scripts/

# Set working directory
WORKDIR /workspace

# Default command
CMD ["/scripts/build-packages.sh"]
