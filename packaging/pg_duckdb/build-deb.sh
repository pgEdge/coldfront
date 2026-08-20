#!/usr/bin/env bash
set -euo pipefail

# Environment variables
BUILD_DIR="/tmp/pg_deb_build"
SRC_DIR="${BUILD_DIR}/pg_duckdb-${PG_DUCKDB_VERSION}"

CWD="$(pwd)"

export DEBIAN_FRONTEND=noninteractive

# Only the owner major (the latest — see common.sh) packages the shared DuckDB
# engine as pgedge-libduckdb; every other major deletes its identical copy.
# debian/rules reads both of these from the environment.
if [ "${PG_MAJOR_VERSION}" = "${LIBDUCKDB_OWNER_PG_MAJOR}" ]; then
  export LIBDUCKDB_OWNER=yes
else
  export LIBDUCKDB_OWNER=no
fi

# LIBDUCKDB_DIR comes from common.sh and is used for both the RPATH (below) and
# the install location (debian/rules reads it from the environment).

# Upper bound for the engine dependency — DuckDB's C++ ABI is tied to the
# upstream version, so 1.5.4 must never resolve against 1.5.5. Bumps the last
# component: 1.5.4 -> 1.5.5.
LIBDUCKDB_ENGINE_NEXT="$(awk -F. '{ $NF = $NF + 1; print }' OFS=. <<< "${PG_DUCKDB_ENGINE_VERSION}")"

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
    # Teach pg_duckdb.so where the shared engine lives. Upstream links it with a
    # plain -lduckdb plus -Wl,-rpath,$(PG_LIB), which only worked while
    # libduckdb.so sat in the PG libdir; it now ships in LIBDUCKDB_DIR, so add
    # that to the RPATH. Makefile.global is included AFTER $(PGXS), and PGXS
    # expands SHLIB_LINK when it links, so appending here still lands.
    printf '\nSHLIB_LINK += -Wl,-rpath,%s\n' "${LIBDUCKDB_DIR}" >> Makefile.global
  )

  echo "Moving Debian packaging into source directory..."
  cp -rp "${CWD}/${COMPONENT_NAME}/deb/debian" "$SRC_DIR/"
  cd "$SRC_DIR"
  cp debian/control.in debian/control
  # The shared-engine stanza is appended ONLY for the owner major; the other
  # majors must not declare pgedge-libduckdb at all, or the release would push
  # several same-version builds of it and reprepro would reject the second.
  if [ "${LIBDUCKDB_OWNER}" = "yes" ]; then
    echo "PG ${PG_MAJOR_VERSION} is the libduckdb owner — building pgedge-libduckdb here"
    cat debian/control.libduckdb.in >> debian/control
  else
    echo "PG ${PG_MAJOR_VERSION} is not the libduckdb owner (${LIBDUCKDB_OWNER_PG_MAJOR} is) — engine comes from pgedge-libduckdb"
    rm -f debian/pgedge-libduckdb.install
  fi
  rm -f debian/control.in debian/control.libduckdb.in
  sed -i "s|PG_MAJOR_VERSION|${PG_MAJOR_VERSION}|g" debian/control
  sed -i "s|DUCKDB_ENGINE_VERSION|${PG_DUCKDB_ENGINE_VERSION}|g;s|DUCKDB_ENGINE_NEXT|${LIBDUCKDB_ENGINE_NEXT}|g" \
     debian/control
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
