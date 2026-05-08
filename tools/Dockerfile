# OpenWRT SDK build harness for openwrt-openziti.
#
# The image installs SDK build prerequisites and downloads an OpenWRT 23.05.x
# SDK tarball. Both the target identifier and the SDK URL are build args so
# we can swap targets without rebuilding the heavy apt layer.
#
# Defaults target aarch64_cortex-a53 via mvebu/cortexa53 in 23.05.5, which is
# a stable 23.05.5 aarch64_cortex-a53 SDK. For the GL-BE3600 (IPQ5332,
# qualcommax/ipq53xx) you typically need a 23.05-SNAPSHOT SDK; pass
# OPENWRT_SDK_URL to override.

FROM debian:bookworm-slim

ARG OPENWRT_VERSION=23.05.5
ARG OPENWRT_TARGET=aarch64_cortex-a53
# Full SDK URL is supplied by the host build script -- it knows the
# target -> (subpath, filename) mapping. Default works for aarch64_cortex-a53
# in 23.05.5 via mvebu/cortexa53.
ARG OPENWRT_SDK_URL=https://downloads.openwrt.org/releases/23.05.5/targets/mvebu/cortexa53/openwrt-sdk-23.05.5-mvebu-cortexa53_gcc-12.3.0_musl.Linux-x86_64.tar.xz

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libncurses-dev \
    zlib1g-dev \
    gawk \
    git \
    gettext \
    libssl-dev \
    xsltproc \
    rsync \
    wget \
    unzip \
    python3 \
    python3-distutils \
    file \
    ca-certificates \
    sudo \
    swig \
    time \
    zstd \
 && rm -rf /var/lib/apt/lists/*

# Non-root build user (OpenWRT SDK refuses to build as root).
RUN useradd -m -u 1000 -s /bin/bash builder \
 && echo "builder ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/builder

USER builder
WORKDIR /home/builder

# Re-declare the args we actually use after the USER switch so they remain in scope.
ARG OPENWRT_VERSION
ARG OPENWRT_TARGET
ARG OPENWRT_SDK_URL

ENV OPENWRT_VERSION=${OPENWRT_VERSION}
ENV OPENWRT_TARGET=${OPENWRT_TARGET}
ENV OPENWRT_SDK_URL=${OPENWRT_SDK_URL}

RUN echo "Downloading SDK from: ${OPENWRT_SDK_URL}" \
 && wget -q -O /tmp/sdk.archive "${OPENWRT_SDK_URL}" \
 && mkdir -p /home/builder/sdk \
 && tar -xf /tmp/sdk.archive -C /home/builder/sdk --strip-components=1 \
 && rm /tmp/sdk.archive

WORKDIR /home/builder/sdk

# /feed is mounted at runtime and points at the repo's package/ directory.
# /out is the artifact extraction directory.
VOLUME ["/feed", "/out"]

CMD ["/bin/bash"]
