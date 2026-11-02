#Author: Nakul Sudarshan (with help from Copilot and Claude) 

# ctrlX app builder (rootless Docker, Core24, amd64 host).
#
# One multi-language definition: .NET, C++, Go, Node.js, Python, Java. Tool layers for further
# languages go below the marked line.
# The ctrlX SDK is downloaded unmodified; only the sample project directories
# are removed, because the project sources and snapcraft.yaml are supplied by
# the user at run time (see container-build.sh).
#
# Build context: this directory only (Dockerfile + container-build.sh).
# All versions and checksums are pinned in the ARG lines below. Every download is verified.

# ---------------------------------------------------------------------------
# Stage 1: download, verify and unpack the inputs
# ---------------------------------------------------------------------------
FROM ubuntu:24.04@sha256:24737cef17f4e22b1977df7d9a05e77c4e28b7da5b8911f8d8ccda136bf3573c AS fetch

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
&& apt-get install --yes --no-install-recommends \
    ca-certificates curl squashfs-tools unzip \
&& rm -rf /var/lib/apt/lists/*

WORKDIR /dl

# Snapcraft 9.2.1 (revision 19387) and Core24 20260824 (revision 2124), amd64.
ARG SNAPCRAFT_VERSION=9.2.1
ARG SNAPCRAFT_URL=https://api.snapcraft.io/api/v1/snaps/download/vMTKRaLjnOJQetI78HjntT37VuoyssFE_19387.snap
ARG SNAPCRAFT_SHA256=0ceae4746d57a3ebd6e657bce2de8603881f4b9ccf27dcfcf28473e8006a5bd0
ARG CORE24_VERSION=20260824
ARG CORE24_URL=https://api.snapcraft.io/api/v1/snaps/download/dwTAh7MZZ01zyriOZErqd1JynQLiOGvM_2124.snap
ARG CORE24_SHA256=e950f61a36652f18817294875bcafb08d273ccc3c44b3f5fbf01296100078efb

RUN curl --fail --silent --show-error --location --output snapcraft.snap "$SNAPCRAFT_URL" \
&& echo "$SNAPCRAFT_SHA256  snapcraft.snap" | sha256sum --check -
RUN curl --fail --silent --show-error --location --output core24.snap "$CORE24_URL" \
&& echo "$CORE24_SHA256  core24.snap" | sha256sum --check -

# Snapcraft runs unpacked (no snapd daemon). Device nodes are excluded because
# they cannot be created under the rootless user-namespace mapping.
RUN mkdir -p /out/snap/core24 /out/snap/snapcraft \
&& unsquashfs -no-progress -excludes -d /out/snap/core24/current core24.snap dev \
&& unsquashfs -no-progress -excludes -d /out/snap/snapcraft/current snapcraft.snap dev \
&& grep -Fx "version: ${SNAPCRAFT_VERSION}" /out/snap/snapcraft/current/meta/snap.yaml \
&& grep -Fx "version: '${CORE24_VERSION}'" /out/snap/core24/current/meta/snap.yaml

# ctrlX AUTOMATION SDK 4.6.0 (release archive, tag commit
# 65228210674f5f70cd0c9ec990180d05fa3fa196). SDK files are never modified.
# Only the sample project directories (sources and snapcraft.yaml) are removed;
# group-level files such as samples-net/nuget.config and
# samples-node/build-node-app.sh stay, because projects refer to them.
ARG SDK_URL=https://github.com/boschrexroth/ctrlx-automation-sdk/releases/download/4.6.0/ctrlx-automation-sdk-4.6.0.zip
ARG SDK_SHA256=183aa0e459d90d59cf59ae96db90e5c890841b67cd549f6e5f18e364c5f4b3c7
RUN curl --fail --silent --show-error --location --output sdk.zip "$SDK_URL" \
&& echo "$SDK_SHA256  sdk.zip" | sha256sum --check - \
&& unzip -q sdk.zip -d /tmp/sdk \
&& mv /tmp/sdk/ctrlx-automation-sdk /out/sdk \
&& rm -rf /tmp/sdk sdk.zip \
&& for group in /out/sdk/samples-*; do \
       find "$group" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + ; \
   done

# The SDK Data Layer deb carries owners outside the rootless mapping. A
# root-owned copy is built for the local APT repository; /out/sdk/deb itself
# stays untouched. Control files are compared before and after repacking.
RUN set -eu; \
    mkdir -p /out/normalized-debs /out/evidence; \
    set -- /out/sdk/deb/*.deb; \
    if [ ! -f "$1" ]; then echo "ERROR: no SDK deb packages found" >&2; exit 1; fi; \
    for deb in "$@"; do \
        name=$(basename "$deb"); \
        work=$(mktemp -d); \
        mkdir "$work/package"; \
        dpkg-deb --fsys-tarfile "$deb" > "$work/data.tar"; \
        tar --extract --file="$work/data.tar" --directory="$work/package" \
            --no-same-owner --same-permissions; \
        dpkg-deb --control "$deb" "$work/package/DEBIAN"; \
        dpkg-deb --build --root-owner-group "$work/package" "/out/normalized-debs/$name"; \
        dpkg-deb -f "$deb" > "$work/original-control"; \
        dpkg-deb -f "/out/normalized-debs/$name" > "$work/rebuilt-control"; \
        cmp "$work/original-control" "$work/rebuilt-control"; \
        rm -rf -- "$work"; \
    done; \
    ( cd /out/sdk/deb && sha256sum ./*.deb ) > /out/evidence/original-deb-SHA256SUMS; \
    ( cd /out/normalized-debs && sha256sum ./*.deb ) > /out/evidence/normalized-deb-SHA256SUMS

# .NET SDK 10.0.403 (runtime 10.0.14), linux-x64 (the builder host architecture).
ARG DOTNET_SDK_VERSION=10.0.403
ARG DOTNET_SDK_URL=https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.403/dotnet-sdk-10.0.403-linux-x64.tar.gz
ARG DOTNET_SDK_SHA512=b7b3d8461cf98b07d2552ce9199702fa3ad010ac2671a5f8cd5136f7534e50f6855ba7bbb02b11494563f1d04156276a31cda1103b900e5eecd0d9473dc7b9c5
RUN curl --fail --silent --show-error --location --output dotnet.tar.gz "$DOTNET_SDK_URL" \
&& echo "$DOTNET_SDK_SHA512  dotnet.tar.gz" | sha512sum --check - \
&& mkdir -p /out/dotnet \
&& tar -xzf dotnet.tar.gz -C /out/dotnet

# Go 1.27.3, linux-amd64 (the builder host architecture). The SDK Go samples declare
# build-snaps "go/1.25/stable", which Snapcraft skips inside a container, so the
# compiler is part of the image. GOTOOLCHAIN=local prevents silent toolchain downloads.
ARG GO_VERSION=1.27.3
ARG GO_URL=https://go.dev/dl/go1.27.3.linux-amd64.tar.gz
ARG GO_SHA256=65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40
RUN curl --fail --silent --show-error --location --output go.tar.gz "$GO_URL" \
&& echo "$GO_SHA256  go.tar.gz" | sha256sum --check - \
&& mkdir -p /out/go \
&& tar -xzf go.tar.gz -C /out/go --strip-components=1

# Node.js 24.14.0 (linux-x64 and linux-arm64), pre-seeded into the cache directory that
# the SDK script samples-node/build-node-app.sh reads (nodejs/.cache/v<version>/<arch>),
# so that the script finds a cache hit and downloads nothing. The SDK script itself
# checks no checksum (SDK files are deliberately left unmodified); here the archives are verified.
# SHA-256 values: nodejs.org/dist/v24.14.0/SHASUMS256.txt (fetched 2026-10-29).
# Samples that set another NODE_VERSION make the SDK script download that version.
ARG NODE_VERSION=24.14.0
ARG NODE_X64_SHA256=dbf5b8665dec15e59e6359a517fefb47b23fdb9152d8def975b9bca3dfc6d355
ARG NODE_ARM64_SHA256=f44740cd218de8127f1c44c41510a3a740fa5c9c8d1cdce1c3bedada79f3cde7
RUN set -eu; \
    for pair in "x64 $NODE_X64_SHA256" "arm64 $NODE_ARM64_SHA256"; do \
        set -- $pair; \
        curl --fail --silent --show-error --location --output "node-$1.tar.gz" \
            "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-$1.tar.gz"; \
        echo "$2  node-$1.tar.gz" | sha256sum --check -; \
        mkdir -p "/out/sdk/nodejs/.cache/v${NODE_VERSION}/$1"; \
        tar -xzf "node-$1.tar.gz" -C "/out/sdk/nodejs/.cache/v${NODE_VERSION}/$1" \
            --strip-components=1 --no-same-owner; \
        rm -f "node-$1.tar.gz"; \
    done

# Gradle 9.2.1 distribution. It is not part of the SDK release archive; the SDK Java sample
# scripts copy ../../oss.gradle/*.zip into the project's gradle/wrapper/ directory, and the
# sample's gradle-wrapper.properties names that file. Official checksum:
# https://services.gradle.org/distributions/gradle-9.2.1-bin.zip.sha256
ARG GRADLE_SHA256=72f44c9f8ebcb1af43838f45ee5c4aa9c5444898b3468ab3f4af7b6076c5bc3f
RUN mkdir -p /out/sdk/oss.gradle \
&& curl --fail --silent --show-error --location --output /out/sdk/oss.gradle/gradle-9.2.1-bin.zip \
    https://services.gradle.org/distributions/gradle-9.2.1-bin.zip \
&& echo "$GRADLE_SHA256  /out/sdk/oss.gradle/gradle-9.2.1-bin.zip" | sha256sum --check -

# ---------------------------------------------------------------------------
# Stage 2: the builder image
# ---------------------------------------------------------------------------
FROM ubuntu:24.04@sha256:24737cef17f4e22b1977df7d9a05e77c4e28b7da5b8911f8d8ccda136bf3573c AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Baseline build tools, the .NET runtime dependencies, and the host
# packages of the SDK script scripts/install-required-packages.sh (C/C++ and cgo:
# libssl-dev, libxml2-dev, uuid-dev, libbz2-1.0, libsystemd-dev) with the arm64 cross
# toolchain (crossbuild-essential-arm64). python3-dev is the build package that the
# Snapcraft python plugin would otherwise install on every build.
# openjdk-21-jdk-headless is the host JDK of the SDK Java samples (build-packages);
# the arm64 JRE is a stage-package that Snapcraft resolves from the Ubuntu Ports sources.
# APT packages are not pinned; the installed versions are recorded below.
RUN apt-get update \
&& apt-get install --yes --no-install-recommends \
    ca-certificates git curl cmake pkg-config build-essential libsystemd-dev \
    dpkg-dev python3-venv python3-dev openjdk-21-jdk-headless snapd squashfs-tools binutils \
    crossbuild-essential-arm64 libssl-dev libxml2-dev uuid-dev libbz2-1.0 \
    libc6 libgcc-s1 libgssapi-krb5-2 libicu74 libssl3t64 libstdc++6 zlib1g \
&& rm -rf /var/lib/apt/lists/*

# Foreign architecture arm64 for cross builds: the amd64 sources are restricted to
# amd64 and signed Ubuntu Ports sources are added for arm64 (recipe verified with the Java
# samples), then the arm64 development libraries of the same SDK script are installed.
# Apt package lists are removed afterwards; builds that stage further arm64 packages
# run apt-get update first (container-build.sh).
RUN sed -i '/^Types:/a Architectures: amd64' /etc/apt/sources.list.d/ubuntu.sources \
&& printf '%s\n' \
    'Types: deb' \
    'URIs: http://ports.ubuntu.com/ubuntu-ports/' \
    'Suites: noble noble-updates noble-backports noble-security' \
    'Components: main restricted universe multiverse' \
    'Architectures: arm64' \
    'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' \
    > /etc/apt/sources.list.d/ubuntu-arm64.sources \
&& dpkg --add-architecture arm64 \
&& apt-get update \
&& apt-get install --yes --no-install-recommends \
    libxml2-dev:arm64 uuid-dev:arm64 libbz2-1.0:arm64 libsystemd-dev:arm64 libssl-dev:arm64 \
&& rm -rf /var/lib/apt/lists/*

COPY --from=fetch /out/snap/core24 /snap/core24
COPY --from=fetch /out/snap/snapcraft /snap/snapcraft
COPY --from=fetch /out/sdk /sdk
COPY --from=fetch /out/normalized-debs /opt/ctrlx-automation-sdk/deb
COPY --from=fetch /out/evidence /opt/ctrlx-builder/evidence
COPY --from=fetch /out/dotnet /opt/dotnet
COPY --from=fetch /out/go /usr/local/go

# Local APT repository for the SDK Data Layer and Scheduler packages (the Data Layer
# is also needed by the Python sample's stage-packages; the SDK script
# install-ctrlx-scheduler.sh installs both). The trust and sandbox settings apply to this
# local repository only.
RUN cd /opt/ctrlx-automation-sdk/deb \
&& dpkg-scanpackages -m . > Packages \
&& printf '%s\n' 'deb [trusted=yes] file:/opt/ctrlx-automation-sdk/deb ./' \
    > /etc/apt/sources.list.d/ctrlx-sdk.list \
&& printf '%s\n' 'APT::Sandbox::User "root";' \
    > /etc/apt/apt.conf.d/10ctrlx-sandbox \
&& apt-get update \
&& apt-get install --yes --no-install-recommends ctrlx-datalayer ctrlx-scheduler \
&& rm -rf /var/lib/apt/lists/*

# Snapcraft in host mode: the declared snap environment, not the reference SNAP=1.
ENV SNAP=/snap/snapcraft/current \
    SNAP_NAME=snapcraft \
    SNAP_VERSION=9.2.1 \
    SNAP_REVISION=19387 \
    SNAP_ARCH=amd64 \
    CRAFT_BUILD_ENVIRONMENT=host \
    PYLXD_WARNINGS=none \
    CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1
ENV PATH="/snap/snapcraft/current/libexec/snapcraft:/snap/bin:/opt/dotnet:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

RUN printf '%s\n' '#!/bin/sh' \
    'exec "$SNAP/bin/python" "$SNAP/bin/snapcraft" "$@"' \
    > /usr/local/bin/snapcraft \
&& chmod +x /usr/local/bin/snapcraft

# Project scripts written for a workstation call "sudo snapcraft ..."; the container
# already runs as the (rootless-mapped) root user, so sudo only passes the command on.
RUN printf '%s\n' '#!/bin/sh' \
    'while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done' \
    'exec "$@"' > /usr/local/bin/sudo \
&& chmod +x /usr/local/bin/sudo

ENV DOTNET_ROOT=/opt/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    GOTOOLCHAIN=local

# ----- further language tool layers go here -----

# Fail the image build on an unexpected tool set, and record what was installed.
RUN test "$(dotnet --version)" = 10.0.403 \
&& test "$(go version)" = "go version go1.27.3 linux/amd64" \
&& test "$(/sdk/nodejs/.cache/v24.14.0/x64/bin/node --version)" = v24.14.0 \
&& test -f /sdk/nodejs/.cache/v24.14.0/arm64/bin/node \
&& test -f /sdk/nodejs/ctrlx-datalayer-3.1.1.tgz \
&& test "$(aarch64-linux-gnu-g++ -dumpmachine)" = aarch64-linux-gnu \
&& dpkg --print-foreign-architectures | grep -qx arm64 \
&& dpkg -s libssl-dev:arm64 libsystemd-dev:arm64 ctrlx-scheduler >/dev/null \
&& python3 --version \
&& javac -version 2>&1 | grep -q '^javac 21\.' \
&& test -f /sdk/oss.gradle/gradle-9.2.1-bin.zip \
&& test -f /sdk/java/com.boschrexroth.ctrlx.datalayer-1.4.2.jar \
&& test -f /sdk/scripts/samples-java/libs.versions.toml \
&& dpkg -s python3-dev python3-venv >/dev/null \
&& snapcraft --version \
&& mkdir -p /opt/ctrlx-builder \
&& dpkg-query -W > /opt/ctrlx-builder/installed-packages.txt \
&& printf '%s\n' \
    'ubuntu=24.04@sha256:24737cef17f4e22b1977df7d9a05e77c4e28b7da5b8911f8d8ccda136bf3573c' \
    'snapcraft=9.2.1 revision=19387' \
    'core24=20260824 revision=2124' \
    'sdk=4.6.0 commit=65228210674f5f70cd0c9ec990180d05fa3fa196' \
    'dotnet-sdk=10.0.403' \
    'go=1.27.3' \
    'nodejs=24.14.0 (x64 and arm64, pre-seeded SDK cache)' \
    'apt-foreign-architecture=arm64 (Ubuntu Ports)' \
    "jdk=$(dpkg-query -W -f='${Version}' openjdk-21-jdk-headless) (openjdk-21-jdk-headless)" \
    'gradle=9.2.1 sha256=72f44c9f8ebcb1af43838f45ee5c4aa9c5444898b3468ab3f4af7b6076c5bc3f (/sdk/oss.gradle)' \
    "python3=$(python3 --version | cut -d' ' -f2) (Ubuntu 24.04 package, pip wheels resolved at build time)" \
    "aarch64-linux-gnu-g++=$(aarch64-linux-gnu-g++ -dumpversion)" \
    > /opt/ctrlx-builder/pins.txt

LABEL org.opencontainers.image.title="ctrlX app builder" \
      org.opencontainers.image.description="Rootless-Docker Snapcraft host-mode builder for ctrlX Core24 apps" \
      ctrlx.builder.sdk="4.6.0" \
      ctrlx.builder.snapcraft="9.2.1" \
      ctrlx.builder.dotnet="10.0.403" \
      ctrlx.builder.go="1.27.3" \
      ctrlx.builder.node="24.14.0" \
      ctrlx.builder.gradle="9.2.1"

# Placed last so that script changes do not invalidate the download layers.
COPY --chmod=755 container-build.sh /usr/local/bin/ctrlx-container-build

WORKDIR /build
ENTRYPOINT ["/usr/local/bin/ctrlx-container-build"]
