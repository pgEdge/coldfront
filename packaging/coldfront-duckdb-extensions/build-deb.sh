#!/usr/bin/env bash
set -euo pipefail

CWD="$(pwd)"
export DEBIAN_FRONTEND=noninteractive
ARCH=$(dpkg --print-architecture)      # amd64 | arm64 (== GoReleaser/DuckDB arch)
case "$ARCH" in
  amd64) DUCKDB_PLATFORM=linux_amd64 ;;
  arm64) DUCKDB_PLATFORM=linux_arm64 ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

SRC_DIR="/tmp/pg_deb_build/coldfront-duckdb-extensions-${DUCKDB_EXT_VERSION}"
# CI stages the build-once artifacts here (per-arch, from build-duckdb-ext); when
# present we just repackage them — no compile in the per-distro cell.
PREBUILT="${PREBUILT:-${CWD}/release-artifacts/duckdb-extensions}"

prepare() {

  setup_apt_build_env

  # This function is for debugging purpose if you have your own keys. GH workflow does not need it.
  #import_gpg_keys

  echo "Staging extensions + docs + debian packaging..."
  rm -rf "$SRC_DIR"; mkdir -p "$SRC_DIR"

  if compgen -G "${PREBUILT}/*.duckdb_extension" >/dev/null; then
    # ---- build-once path: reuse the manylinux-built, load-tested binaries ----
    echo "Using prebuilt extensions from ${PREBUILT} (build-once)"
    cp "${PREBUILT}"/*.duckdb_extension "$SRC_DIR/"
  else
    # ---- local / fallback path: build from source in this container ----
    echo "No prebuilt extensions staged — building from source in-cell."
    sudo apt-get install -y \
        build-essential cmake ninja-build git ccache jq wget zip unzip \
        tar autoconf libtool flex bison pkg-config perl
    bash "${CWD}/${COMPONENT_NAME}/build-extensions.sh" "$SRC_DIR"
  fi

  cp "${COMPONENT_NAME}/config/coldfront-duckdb-extensions.conf.sample" "$SRC_DIR/"
  cp "${CWD}/LICENSE.md" "${CWD}/README.md" "$SRC_DIR/"
  cp -rp "${CWD}/${COMPONENT_NAME}/deb/debian" "$SRC_DIR/"

  # Generate the .install with the real versioned/platform path. DuckDB locates
  # extensions under <extdir>/v<engine>/<platform>/ — the version segment is the
  # clean engine version (DUCKDB_VERSION), not the ~-decorated package version.
  cd "$SRC_DIR"
  extrel="${COLDFRONT_EXTDIR#/}"
  dest="${extrel}/v${DUCKDB_VERSION}/${DUCKDB_PLATFORM}"
  {
    for e in iceberg avro azure postgres_scanner; do
      echo "${e}.duckdb_extension ${dest}/"
    done
    echo "coldfront-duckdb-extensions.conf.sample usr/share/pgedge-coldfront-duckdb-extensions/"
    echo "debian/tmp/sbom/* usr/share/pgedge-coldfront-duckdb-extensions/"
  } > debian/pgedge-coldfront-duckdb-extensions.install

  echo "Installing build dependencies..."
  sudo apt-get update
  sudo apt-get build-dep -y .
}

build() {
  cd "$SRC_DIR"
  echo "Building Debian package..."
  DISTRO=$(lsb_release -cs)
  rm -rf debian/changelog
  echo "pgedge-coldfront-duckdb-extensions (${DUCKDB_EXT_VERSION}-${DUCKDB_EXT_BUILDNUM}.${DISTRO}) unstable; urgency=low" >> debian/changelog
  echo "  * Initial Release." >> debian/changelog
  echo " -- pgEdge Build Team <support@pgedge.com>  $(date -R)" >> debian/changelog
  dch -D "$DISTRO" --force-distribution -v "${DUCKDB_EXT_VERSION}-${DUCKDB_EXT_BUILDNUM}.${DISTRO}" "pgEdge ColdFront DuckDB extensions ${DUCKDB_EXT_VERSION} for $DISTRO"

  dpkg-buildpackage -us -uc -b
}

post_build() {
  echo "Copying .deb packages to output..."
  sudo mkdir -p "/output"
  # dpkg-buildpackage writes the .deb to the parent of the source dir.
  rename_ddeb_packages "/tmp/pg_deb_build"
  sudo cp /tmp/pg_deb_build/*.deb "/output" || echo "No .deb packages found."
}
