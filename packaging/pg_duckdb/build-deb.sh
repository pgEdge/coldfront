#!/usr/bin/env bash
set -euo pipefail

# Environment variables
BUILD_DIR="/tmp/pg_deb_build"
SRC_DIR="${BUILD_DIR}/pg_duckdb-${PG_DUCKDB_VERSION}"

CWD="$(pwd)"

export DEBIAN_FRONTEND=noninteractive

prepare() {

  setup_apt_build_env

  # This function is for debugging purpose if you have your own keys. GH workflow does not need it.
  #import_gpg_keys

  echo "Vendoring pg_duckdb @ ${PG_DUCKDB_COMMIT} with bundled DuckDB submodule (v1.5.4)..."
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  git init -q "$SRC_DIR"
  (
    cd "$SRC_DIR"
    git remote add origin "${PG_DUCKDB_REPO}"
    git fetch -q --depth 1 origin "${PG_DUCKDB_COMMIT}"
    git checkout -q FETCH_HEAD
    git submodule update --init --recursive --depth 1
    # See build-rpm.sh: GitHub tarballs omit submodules and the Makefile gates
    # the DuckDB build on a `.git/modules/third_party/duckdb/HEAD` marker. Drop
    # .git but leave the marker so `make` treats the submodule as checked out.
    rm -rf .git
    mkdir -p .git/modules/third_party/duckdb
    touch .git/modules/third_party/duckdb/HEAD
    # pgEdge propagates -fexcess-precision=standard into CXXFLAGS, which gcc
    # rejects for C++. Strip it after PGXS is included (no-op if absent).
    printf '\noverride CXXFLAGS := $(filter-out -fexcess-precision=standard,$(CXXFLAGS))\n' >> Makefile.global
  )

  echo "Moving Debian packaging into source directory..."
  cp -rp "${CWD}/${COMPONENT_NAME}/deb/debian" "$SRC_DIR/"
  cd "$SRC_DIR"
  cp debian/control.in debian/control
  sed -i "s|PG_MAJOR_VERSION|${PG_MAJOR_VERSION}|g" debian/control
  mv debian/pgedge-postgresql-pg-duckdb.install \
     debian/pgedge-postgresql-${PG_MAJOR_VERSION}-pg-duckdb.install
  sed -i "s|PG_MAJOR_VERSION|${PG_MAJOR_VERSION}|g" \
     debian/pgedge-postgresql-${PG_MAJOR_VERSION}-pg-duckdb.install

  echo "Installing build dependencies..."
  sudo apt-get update
  sudo apt-get build-dep -y .

  # --- bullseye only: build curl >= 7.77 from source for the build (NOT shipped).
  # bullseye ships libcurl 7.74, too old to compile the DuckDB 1.5.x httpfs
  # (CURLSSLOPT_AUTO_CLIENT_CERT, curl >= 7.77). Build it to a build-local prefix
  # and expose it to find_package(CURL); we do NOT rpath it, so the produced .so
  # resolves libcurl.so.4 from the system at runtime (the curl path is unused —
  # ColdFront forces httplib). These exports persist into dpkg-buildpackage below.
  DISTRO=$(lsb_release -cs)
  if [ "$DISTRO" = "bullseye" ]; then
    echo "bullseye: building curl ${CURL_VERSION} from source (build-time only)..."
    local curl_prefix="${BUILD_DIR}/curl-install"
    mkdir -p "$curl_prefix"
    wget -q "https://curl.se/download/curl-${CURL_VERSION}.tar.gz" -O "${BUILD_DIR}/curl.tar.gz"
    tar xf "${BUILD_DIR}/curl.tar.gz" -C "$BUILD_DIR"
    (
      cd "${BUILD_DIR}/curl-${CURL_VERSION}"
      ./configure --with-openssl --prefix="$curl_prefix" --disable-static \
        --without-libpsl --without-libssh2 --without-nghttp2 --without-brotli --without-zstd
      make -j"$(nproc)"
      make install
    )
    export CMAKE_PREFIX_PATH="${curl_prefix}${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
    export PKG_CONFIG_PATH="${curl_prefix}/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export LIBRARY_PATH="${curl_prefix}/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
    export CPATH="${curl_prefix}/include${CPATH:+:$CPATH}"
  fi
}

build() {

  cd "$SRC_DIR"
  echo "Building Debian package..."
  DISTRO=$(lsb_release -cs)
  rm -rf debian/changelog
  echo "pgedge-pg-duckdb (${PG_DUCKDB_VERSION}-${PG_DUCKDB_BUILDNUM}.${DISTRO}) unstable; urgency=low" >> debian/changelog
  echo "  * Initial Release." >> debian/changelog
  echo " -- pgEdge Build Team <support@pgedge.com>  $(date -R)" >> debian/changelog
  dch -D "$DISTRO" --force-distribution -v "${PG_DUCKDB_VERSION}-${PG_DUCKDB_BUILDNUM}.${DISTRO}" "pgEdge pg_duckdb ${PG_DUCKDB_VERSION} for $DISTRO"

  PATH=/usr/lib/postgresql/${PG_MAJOR_VERSION}/bin:$PATH dpkg-buildpackage -us -uc -b
}

post_build() {
  echo "Copying .deb packages to output..."
  sudo mkdir -p "/output"
  # Rename .ddeb files to .deb files
  rename_ddeb_packages "$BUILD_DIR"
  sudo cp "$BUILD_DIR"/*.deb "/output" || echo "No .deb packages found."
}
