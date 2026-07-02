#!/usr/bin/env bash
set -euo pipefail

CWD="$(pwd)"
export DEBIAN_FRONTEND=noninteractive
ARCH=$(dpkg --print-architecture)      # amd64 | arm64 (== GoReleaser/DuckDB arch)
case "$ARCH" in
  amd64) DUCKDB_PLATFORM=linux_amd64; VCPKG_TRIPLET=x64-linux ;;
  arm64) DUCKDB_PLATFORM=linux_arm64; VCPKG_TRIPLET=arm64-linux ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

BUILD_ROOT="/tmp/cf-duckdb-ext-build"
ICE="${BUILD_ROOT}/duckdb-iceberg"
SRC_DIR="/tmp/pg_deb_build/coldfront-duckdb-extensions-${DUCKDB_EXT_VERSION}"

prepare() {

  setup_apt_build_env

  # This function is for debugging purpose if you have your own keys. GH workflow does not need it.
  #import_gpg_keys

  echo "Installing duckdb-iceberg build toolchain..."
  sudo apt-get install -y \
      build-essential cmake ninja-build git ccache jq wget zip unzip \
      tar autoconf libtool flex bison pkg-config perl

  echo "Cloning + patching duckdb-iceberg (against DuckDB v${DUCKDB_VERSION})..."
  rm -rf "$BUILD_ROOT"; mkdir -p "$BUILD_ROOT"
  git clone --filter=blob:none --no-checkout "${ICEBERG_REPO}" "$ICE"
  git -C "$ICE" fetch --depth 80 origin "${ICEBERG_BRANCH}"
  git -C "$ICE" checkout "${ICEBERG_REF}"
  git -C "$ICE" submodule update --init --recursive --depth 1 --jobs 8
  rm -rf "$ICE/duckdb"
  git clone --depth 1 --branch "v${DUCKDB_VERSION}" --recurse-submodules "${DUCKDB_REPO}" "$ICE/duckdb"
  git clone "${VCPKG_REPO}" "${BUILD_ROOT}/vcpkg"
  "${BUILD_ROOT}/vcpkg/bootstrap-vcpkg.sh" -disableMetrics

  cp "${CWD}/docker/iceberg-azure-extension-config-v15.cmake" "$ICE/extension_config.cmake"
  for p in iceberg-bakery-aware-commit-refresh-v15 \
           iceberg-manifest-list-format-version-v15 \
           iceberg-manifest-content-v15 \
           iceberg-data-file-format-v15; do
    git -C "$ICE" apply --check "${CWD}/docker/${p}.patch"
    git -C "$ICE" apply         "${CWD}/docker/${p}.patch"
  done

  echo "Building extensions (make release)..."
  (
    cd "$ICE"
    export VCPKG_TOOLCHAIN_PATH="${BUILD_ROOT}/vcpkg/scripts/buildsystems/vcpkg.cmake"
    export VCPKG_ROOT="${BUILD_ROOT}/vcpkg"
    export VCPKG_TARGET_TRIPLET="$VCPKG_TRIPLET" VCPKG_HOST_TRIPLET="$VCPKG_TRIPLET"
    export USE_MERGED_VCPKG_MANIFEST=1
    export EXT_CONFIG="${ICE}/extension_config.cmake"
    export OVERRIDE_GIT_DESCRIBE="v${DUCKDB_VERSION}"
    # Cap parallelism to bound peak memory (DuckDB can OOM at high -j).
    export CMAKE_BUILD_PARALLEL_LEVEL=4
    make -j4 release
  )

  echo "Staging built extensions + docs + debian packaging..."
  rm -rf "$SRC_DIR"; mkdir -p "$SRC_DIR"
  for e in iceberg avro azure postgres_scanner; do
    cp "${ICE}/build/release/extension/${e}/${e}.duckdb_extension" "$SRC_DIR/"
  done
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
