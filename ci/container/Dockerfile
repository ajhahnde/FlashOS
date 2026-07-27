# syntax=docker/dockerfile:1

# This image is a deliberately thin FlashOS-owned CI boundary around the
# inherited Redox cross-build environment. Product sources are mounted at run
# time, so the image contains tools only and can be cached independently.
# The base image is pinned by digest, not by tag. A moving tag would let the
# same FlashOS commit produce a different image on a later build.
ARG REDOX_BASE_IMAGE=redoxos/redox-base-x86_64@sha256:08e2c950c0b5f3b5a0f5ea324a5666e8071da9373a3b5d5ef6b12b2f777cda59
FROM ${REDOX_BASE_IMAGE}

LABEL org.opencontainers.image.title="FlashOS CI build environment"
LABEL org.opencontainers.image.description="Reproducible x86_64 FlashOS image-build toolchain"
LABEL org.opencontainers.image.source="https://github.com/ajhahnde/FlashOS"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# rustup-init comes from the immutable per-version archive rather than the
# sh.rustup.rs redirect, and its checksum is verified before it is executed.
# The toolchain matches rust-toolchain.toml so the container cannot install a
# channel the workspace would then replace.
ARG RUSTUP_VERSION=1.29.0
ARG RUSTUP_SHA256=4acc9acc76d5079515b46346a485974457b5a79893cfb01112423c89aeb5aa10
ARG RUST_TOOLCHAIN=nightly-2026-05-24

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
       git \
       libarchive-tools \
    && rm -rf /var/lib/apt/lists/* \
    && curl --fail --show-error --silent --proto '=https' --tlsv1.2 \
       "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/x86_64-unknown-linux-gnu/rustup-init" \
       -o /tmp/rustup-init \
    && echo "${RUSTUP_SHA256}  /tmp/rustup-init" | sha256sum --check --strict - \
    && chmod +x /tmp/rustup-init \
    && /tmp/rustup-init -y --default-toolchain "${RUST_TOOLCHAIN}" --profile minimal \
    && rm /tmp/rustup-init

ENV PATH="/root/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV PODMAN_BUILD=0
ENV SKIP_CHECK_TOOLS=1
ENV REPO_BINARY=1
ENV REPO_NONSTOP=0
ENV FSTOOLS_NO_MOUNT=1

WORKDIR /workspace
