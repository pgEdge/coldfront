#!/usr/bin/env bash
set -euo pipefail

# Environment variables
BUILD_DIR="/tmp/pg_deb_build"
SRC_DIR="${BUILD_DIR}/coldfront-${COLDFRONT_VERSION}"

CWD="$(pwd)"

export DEBIAN_FRONTEND=noninteractive

prepare() {

  setup_apt_build_env

  # This function is for debugging purpose if you have your own keys. GH workflow does not need it.
  #import_gpg_keys

  echo "Packing the coldfront extension source..."
  rm -rf "$BUILD_DIR"
  mkdir -p "$SRC_DIR"
  cp -rp "${CWD}/extension/coldfront/." "$SRC_DIR/"
  # License + README travel with the package (PostgreSQL-licensed).
  cp "${CWD}/LICENSE.md" "${CWD}/README.md" "$SRC_DIR/"

  echo "Moving Debian packaging into source directory..."
  cp -rp "${CWD}/${COMPONENT_NAME}/deb/debian" "$SRC_DIR/"
  cd "$SRC_DIR"
  cp debian/control.in debian/control
  sed -i "s|PG_MAJOR_VERSION|${PG_MAJOR_VERSION}|g" debian/control
  mv debian/pgedge-postgresql-coldfront.install \
     debian/pgedge-postgresql-${PG_MAJOR_VERSION}-coldfront.install
  sed -i "s|PG_MAJOR_VERSION|${PG_MAJOR_VERSION}|g" \
     debian/pgedge-postgresql-${PG_MAJOR_VERSION}-coldfront.install

  echo "Installing build dependencies..."
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
  dch -D "$DISTRO" --force-distribution -v "${COLDFRONT_VERSION}-${COLDFRONT_BUILDNUM}.${DISTRO}" "pgEdge ColdFront ${COLDFRONT_VERSION} for $DISTRO"

  PATH=/usr/lib/postgresql/${PG_MAJOR_VERSION}/bin:$PATH dpkg-buildpackage -us -uc -b
}

post_build() {
  echo "Copying .deb packages to output..."
  sudo mkdir -p "/output"
  # Rename .ddeb files to .deb files
  rename_ddeb_packages "$BUILD_DIR"
  sudo cp "$BUILD_DIR"/*.deb "/output" || echo "No .deb packages found."
}
