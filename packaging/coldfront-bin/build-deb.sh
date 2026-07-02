#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR="/tmp/pg_deb_build"
SRC_DIR="${BUILD_DIR}/coldfront-${COLDFRONT_VERSION}"
CWD="$(pwd)"

export DEBIAN_FRONTEND=noninteractive
ARCH=$(dpkg --print-architecture)      # amd64 | arm64 (== GoReleaser arch)

TAG_VERSION="${COLDFRONT_BRANCH#v}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${CWD}/release-artifacts}"
RELEASE_URL="https://github.com/pgEdge/ColdFront/releases/download/${COLDFRONT_BRANCH}"

# Prefer the workflow-staged tarball (release-artifacts/); else download.
stage() {
  local local_name="$1" remote_name="$2" dest="$3"
  if [ -f "${ARTIFACT_DIR}/${local_name}" ]; then
    cp "${ARTIFACT_DIR}/${local_name}" "${dest}"
  else
    wget -q "${RELEASE_URL}/${remote_name}" -O "${dest}"
  fi
}

prepare() {

  setup_apt_build_env

  # This function is for debugging purpose if you have your own keys. GH workflow does not need it.
  #import_gpg_keys

  echo "Staging ColdFront binaries tarball (${ARCH})..."
  rm -rf "$BUILD_DIR"
  mkdir -p "$SRC_DIR"
  stage "coldfront.tar.gz" "coldfront_${TAG_VERSION}_linux_${ARCH}.tar.gz" \
        "${BUILD_DIR}/coldfront.tar.gz"
  tar -C "$SRC_DIR" -xzf "${BUILD_DIR}/coldfront.tar.gz"

  echo "Moving Debian packaging into source directory..."
  cp -rp "${CWD}/${COMPONENT_NAME}/deb/debian" "$SRC_DIR/"

  echo "Installing build dependencies..."
  cd "$SRC_DIR"
  sudo apt-get update
  sudo apt-get build-dep -y .
}

build() {

  cd "$SRC_DIR"
  echo "Building Debian package..."
  DISTRO=$(lsb_release -cs)
  rm -rf debian/changelog
  echo "pgedge-coldfront (${COLDFRONT_VERSION}-${COLDFRONT_BUILDNUM}.${DISTRO}) unstable; urgency=low" >> debian/changelog
  echo "  * Initial Release." >> debian/changelog
  echo " -- pgEdge Build Team <support@pgedge.com>  $(date -R)" >> debian/changelog
  dch -D "$DISTRO" --force-distribution -v "${COLDFRONT_VERSION}-${COLDFRONT_BUILDNUM}.${DISTRO}" "pgEdge ColdFront tools ${COLDFRONT_VERSION} for $DISTRO"

  dpkg-buildpackage -us -uc -b
}

post_build() {
  echo "Copying .deb packages to output..."
  sudo mkdir -p "/output"
  rename_ddeb_packages "$BUILD_DIR"
  sudo cp "$BUILD_DIR"/*.deb "/output" || echo "No .deb packages found."
}
