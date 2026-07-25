# syntax=docker/dockerfile:1

# This image is a deliberately thin FlashOS-owned CI boundary around the
# inherited Redox cross-build environment. Product sources are mounted at run
# time, so the image contains tools only and can be cached independently.
ARG REDOX_BASE_IMAGE=redoxos/redox-base-x86_64
FROM ${REDOX_BASE_IMAGE}

LABEL org.opencontainers.image.title="FlashOS CI build environment"
LABEL org.opencontainers.image.description="Reproducible x86_64 FlashOS image-build toolchain"
LABEL org.opencontainers.image.source="https://github.com/ajhahnde/FlashOS"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/* \
    && curl --fail --show-error --silent --proto '=https' --tlsv1.2 \
       https://sh.rustup.rs -o /tmp/rustup-init.sh \
    && sh /tmp/rustup-init.sh -y --default-toolchain stable --profile minimal \
    && rm /tmp/rustup-init.sh

ENV PATH="/root/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV PODMAN_BUILD=0
ENV SKIP_CHECK_TOOLS=1
ENV REPO_BINARY=1
ENV REPO_NONSTOP=0
ENV FSTOOLS_NO_MOUNT=1

WORKDIR /workspace
