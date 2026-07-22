#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR="/tmp/pg_deb_build"
SRC_DIR="${BUILD_DIR}/lakekeeper-${LAKEKEEPER_VERSION}"
CWD="$(pwd)"

export DEBIAN_FRONTEND=noninteractive

# Map the dpkg arch to the upstream target-triple prefix.
DEB_ARCH=$(dpkg --print-architecture)   # amd64 | arm64
case "$DEB_ARCH" in
  amd64) UNAME_ARCH=x86_64 ;;
  arm64) UNAME_ARCH=aarch64 ;;
  *) echo "unsupported arch: $DEB_ARCH" >&2; exit 1 ;;
esac

# Strip any '~pretag' for the release tag/URL: LAKEKEEPER_VERSION carries it for
# the deb package version (e.g. 0.13.1~test1), but the GitHub release tag is the
# clean upstream version (v0.13.1).
RELEASE_URL="https://github.com/lakekeeper/lakekeeper/releases/download/v${LAKEKEEPER_VERSION%%~*}"
REPO_RAW="https://raw.githubusercontent.com/lakekeeper/lakekeeper/v${LAKEKEEPER_VERSION%%~*}"

prepare() {
  setup_apt_build_env

  # This function is for debugging purpose if you have your own keys. GH workflow does not need it.
  #import_gpg_keys

  echo "Downloading lakekeeper ${LAKEKEEPER_VERSION%%~*} binary (${UNAME_ARCH})..."
  rm -rf "$BUILD_DIR"
  mkdir -p "$SRC_DIR"
  local tarball="lakekeeper-${UNAME_ARCH}-unknown-linux-gnu.tar.gz"
  wget -q "${RELEASE_URL}/${tarball}" -O "${BUILD_DIR}/${tarball}"
  tar -C "$SRC_DIR" -xzf "${BUILD_DIR}/${tarball}"

  # LICENSE + NOTICE are not inside the tarball; fetch them from the repo tag.
  echo "Fetching LICENSE + NOTICE from the ${LAKEKEEPER_VERSION} tag..."
  wget -q "${REPO_RAW}/LICENSE" -O "${SRC_DIR}/LICENSE"
  wget -q "${REPO_RAW}/NOTICE"  -O "${SRC_DIR}/NOTICE"
  cp "${CWD}/${COMPONENT_NAME}/README.md" "${SRC_DIR}/README.md"

  echo "Staging Debian packaging..."
  cp -rp "${CWD}/${COMPONENT_NAME}/deb/debian" "$SRC_DIR/"
  cp "${CWD}/${COMPONENT_NAME}/common/lakekeeper.service" "$SRC_DIR/debian/lakekeeper.service"
  cp "${CWD}/${COMPONENT_NAME}/common/lakekeeper.env"     "$SRC_DIR/debian/lakekeeper.env"

  echo "Installing build dependencies..."
  cd "$SRC_DIR"
  sudo apt-get update
  sudo apt-get build-dep -y .
}

build() {
  cd "$SRC_DIR"
  echo "Building Debian package..."
  DISTRO=$(lsb_release -cs)
  rm -f debian/changelog
cat > debian/changelog <<EOF
pgedge-lakekeeper (${LAKEKEEPER_VERSION}-${LAKEKEEPER_BUILDNUM}.${DISTRO}) unstable; urgency=medium

  * Package Lakekeeper ${LAKEKEEPER_VERSION} for ${DISTRO}.

 -- pgEdge Build Team <support@pgedge.com>  $(date -R)
EOF

  dpkg-buildpackage -us -uc -b
}

post_build() {
  echo "Copying .deb packages to output..."
  sudo mkdir -p "/output"
  rename_ddeb_packages "$BUILD_DIR"
  sudo cp "$BUILD_DIR"/*.deb "/output" || echo "No .deb packages found."
}
