#!/bin/bash
set -euo pipefail

RHEL="$(rpm --eval %rhel)"

# Only the owner major (the latest — see common.sh) packages the shared DuckDB
# engine; every other major deletes its identical copy and links against it.
# The comparison lives here, not in the spec, so RPM and DEB decide it the same
# way from the same variable.
if [ "${PG_MAJOR_VERSION}" = "${LIBDUCKDB_OWNER_PG_MAJOR}" ]; then
  WITH_LIBDUCKDB=1
else
  WITH_LIBDUCKDB=0
fi

prepare() {
  setup_dnf_build_env

  echo "Copying packaging files..."
  cp "${COMPONENT_NAME}/rpm/pg_duckdb.spec" ~/rpmbuild/SPECS/

  echo "Vendoring pg_duckdb @ ${PG_DUCKDB_COMMIT} with bundled DuckDB submodule (v1.5.4)..."
  rm -rf "/tmp/pg_duckdb-${PG_DUCKDB_VERSION}"
  git init -q "/tmp/pg_duckdb-${PG_DUCKDB_VERSION}"
  (
    cd "/tmp/pg_duckdb-${PG_DUCKDB_VERSION}"
    git remote add origin "${PG_DUCKDB_REPO}"
    git fetch -q --depth 1 origin "${PG_DUCKDB_COMMIT}"
    git checkout -q FETCH_HEAD
    git submodule update --init --recursive --depth 1
    # GitHub auto-tarballs omit submodules, and pg_duckdb's Makefile gates the
    # DuckDB build on a `.git/modules/third_party/duckdb/HEAD` marker. Drop the
    # heavy .git history but leave that marker so `make` treats the submodule as
    # already checked out and never tries to fetch it (offline-safe build).
    rm -rf .git
    mkdir -p .git/modules/third_party/duckdb
    touch .git/modules/third_party/duckdb/HEAD
  )
  tar czf ~/rpmbuild/SOURCES/pg_duckdb-${PG_DUCKDB_VERSION}.tar.gz \
    -C /tmp "pg_duckdb-${PG_DUCKDB_VERSION}"

  # curl source for the EL9 build-time-only libcurl (Source1). Always staged so
  # rpmbuild finds Source1; only consumed by %build on EL9 (el10 uses system curl).
  echo "Staging curl ${CURL_VERSION} source (build-time, EL9 only)..."
  wget -q "https://curl.se/download/curl-${CURL_VERSION}.tar.gz" \
    -O ~/rpmbuild/SOURCES/curl-${CURL_VERSION}.tar.gz

  # This function is for debugging purpose if you have your own keys. GH workflow does not need it.
  #import_gpg_keys

  # with_libduckdb must be defined here too — builddep parses the same spec, and
  # an undefined macro in the %if would abort the parse.
  echo "🔧 Installing RPM build dependencies..."
  dnf builddep -y \
    --define "pgmajorversion ${PG_MAJOR_VERSION}" \
    --define "pginstdir /usr/pgsql-${PG_MAJOR_VERSION}" \
    --define "pg_duckdb_version ${PG_DUCKDB_VERSION}" \
    --define "pg_duckdb_buildnum ${PG_DUCKDB_BUILDNUM}" \
    --define "curl_version ${CURL_VERSION}" \
    --define "with_libduckdb ${WITH_LIBDUCKDB}" \
    --define "libduckdb_dir ${LIBDUCKDB_DIR}" \
    ~/rpmbuild/SPECS/pg_duckdb.spec
}

build() {
  echo "Building RPM and SRPM..."
  if [ "${WITH_LIBDUCKDB}" = "1" ]; then
    echo "  PG ${PG_MAJOR_VERSION} is the libduckdb owner — this cell also builds pgedge-libduckdb"
  else
    echo "  PG ${PG_MAJOR_VERSION} is not the libduckdb owner (${LIBDUCKDB_OWNER_PG_MAJOR} is) — engine comes from pgedge-libduckdb"
  fi
  QA_RPATHS=$(( 0xffff )) rpmbuild -ba ~/rpmbuild/SPECS/pg_duckdb.spec \
    --define "pgmajorversion ${PG_MAJOR_VERSION}" \
    --define "pginstdir /usr/pgsql-${PG_MAJOR_VERSION}" \
    --define "pg_duckdb_version ${PG_DUCKDB_VERSION}" \
    --define "pg_duckdb_buildnum ${PG_DUCKDB_BUILDNUM}" \
    --define "curl_version ${CURL_VERSION}" \
    --define "with_libduckdb ${WITH_LIBDUCKDB}" \
    --define "libduckdb_dir ${LIBDUCKDB_DIR}"
}

post_build() {
  echo "📤 Copying built RPMs to /output..."
  mkdir -p /output
  cp -v ~/rpmbuild/RPMS/*/*.rpm /output/ || echo "No binary RPMs found"
  cp -v ~/rpmbuild/SRPMS/*.src.rpm /output/ || echo "No SRPM found"

  sign_rpms /output/*.rpm
  validate_signatures /output/*.rpm
}
