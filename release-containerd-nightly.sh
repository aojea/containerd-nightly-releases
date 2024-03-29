#!/usr/bin/env bash

#   Copyright The containerd Authors.

#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at

#       http://www.apache.org/licenses/LICENSE-2.0

#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

#
# Releases and cross compile containerd.
# Ref: https://wiki.debian.org/CrossToolchains
set -eu -o pipefail

install_dependencies() {
  dpkg --add-architecture ${1}
  apt-get install crossbuild-essential-${1}
  apt-get install libseccomp-dev:${1}
}

# Only runs in x86 architecture
if [ $(go env GOARCH) != "amd64" ]; then 
    exit 1
fi

# Obtain current directory
CONTAINERD_DIR=${GOPATH}/src/github.com/containerd/containerd
RUNC_DIR=${GOPATH}/src/github.com/opencontainers/runc

# Add repositories with multiple architectures
source /etc/os-release
cat <<EOF > /etc/apt/sources.list.d/ports.list
deb [arch=armhf,arm64,ppc64el,s390x] http://ports.ubuntu.com/ubuntu-ports/ ${VERSION_CODENAME} main multiverse restricted universe
deb [arch=armhf,arm64,ppc64el,s390x] http://ports.ubuntu.com/ubuntu-ports/ ${VERSION_CODENAME}-updates main multiverse restricted universe
EOF

apt-get update || true

# Create amd64 releases
echo "Creating amd64 release ..."
# Name releases using Golang's "pseudo-version"
cd ${CONTAINERD_DIR}
gitUnix="$(git log -1 --pretty='%ct')"
gitDate="$(date --utc --date "@$gitUnix" +'%Y%m%d%H%M%S')"
gitCommit="$(git log -1 --pretty='%h')"
VERSION="0.0.0-${gitDate}-${gitCommit}"
make release VERSION=${VERSION}
# We need our own runc for nightlies
# we use the same version that containerd for consistency
# https://github.com/containerd/containerd/blob/master/RUNC.md
cd ${RUNC_DIR}
make release VERSION=${VERSION}
cp release/${VERSION}/runc.amd64 ${CONTAINERD_DIR}/releases/

# Cross compile for the other architectures
CONTAINERD_ARCH=(
    arm
    arm64
    ppc64le
    s390x
)

# Remove libssecomp shared libraries from default location
# to avoid conflicts crosscompiling
rm /usr/local/lib/libseccomp* || true

for arch in "${CONTAINERD_ARCH[@]}"; do
    # Select the right compiler for each architecture
    # and install dependencies
    case ${arch} in
    arm)
      install_dependencies "armhf"
      ARCH_PREFIX="arm-linux-gnueabihf"
      ;;
    arm64)
      install_dependencies "arm64"
      ARCH_PREFIX="aarch64-linux-gnu"
      ;;
    ppc64le)
      install_dependencies "ppc64el"
      ARCH_PREFIX="powerpc64le-linux-gnu"
      ;;
    s390x)
      install_dependencies "s390x"
      ARCH_PREFIX="s390x-linux-gnu"
      ;;
    esac

    echo "Creating ${arch} release ..."
    # Create containerd release
    cd ${CONTAINERD_DIR}
    make clean
    LD_LIBRARY_PATH=/usr/lib/${ARCH_PREFIX} \
    make release \
        GOARCH=${arch} \
        CC=${ARCH_PREFIX}-gcc \
        CGO_ENABLED=1 \
        VERSION=${VERSION}
    # Create runc release
    cd ${RUNC_DIR}
    make clean
    LD_LIBRARY_PATH=/usr/lib/${ARCH_PREFIX} \
    make release \
        GOARCH=${arch} \
        CC=${ARCH_PREFIX}-gcc \
        VERSION=${VERSION}
    cp release/${VERSION}/runc.${arch} ${CONTAINERD_DIR}/releases/
done
