#!/bin/bash
set -euo pipefail

RHEL="$(rpm --eval %rhel)"
CWD="$(pwd)"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  DUCKDB_PLATFORM=linux_amd64 ;;
  aarch64) DUCKDB_PLATFORM=linux_arm64 ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

STAGE="/tmp/coldfront-duckdb-extensions-${DUCKDB_EXT_VERSION}"
# CI stages the build-once artifacts here (per-arch, from build-duckdb-ext); when
# present we just repackage them — no compile in the per-distro cell.
PREBUILT="${PREBUILT:-${CWD}/release-artifacts/duckdb-extensions}"

prepare() {
  setup_dnf_build_env

  echo "Staging extensions + docs for packaging..."
  rm -rf "$STAGE"; mkdir -p "$STAGE"

  if compgen -G "${PREBUILT}/*.duckdb_extension" >/dev/null; then
    # ---- build-once path: reuse the manylinux-built, load-tested binaries ----
    echo "Using prebuilt extensions from ${PREBUILT} (build-once)"
    cp "${PREBUILT}"/*.duckdb_extension "$STAGE/"
  else
    # ---- local / fallback path: build from source in this container ----
    echo "No prebuilt extensions staged — building from source in-cell."
    # DuckDB 1.5.4's extensions (e.g. postgres_scanner) need a modern C++ compiler:
    # EL9's native gcc 11 rejects them, so use gcc-toolset-14 (gcc 14, as the docker
    # recipe does); EL10 ships gcc 14 natively. libasan/libubsan: the
    # extension_configuration phase builds a Debug binary that links ASan.
    if [ "${RHEL}" -lt 10 ]; then
      dnf install -y gcc-toolset-14-gcc-c++ gcc-toolset-14-libasan-devel gcc-toolset-14-libubsan-devel
    else
      dnf install -y gcc gcc-c++ libasan libubsan
    fi
    # perl-core: openssl-from-source (vcpkg) Configure needs FindBin + other core
    # perl modules that EL's minimal perl splits out; perl-core pulls the full set.
    dnf install -y make ninja-build perl-core perl-FindBin perl-IPC-Cmd perl-Time-Piece \
        ccache jq wget zip unzip tar autoconf libtool kernel-headers cmake git flex bison
    bash "${CWD}/${COMPONENT_NAME}/build-extensions.sh" "$STAGE"
  fi

  cp "${COMPONENT_NAME}/config/coldfront-duckdb-extensions.conf.sample" "$STAGE/"
  cp "${CWD}/LICENSE.md" "${CWD}/README.md" "$STAGE/"
  cp "${COMPONENT_NAME}/rpm/coldfront-duckdb-extensions.spec" ~/rpmbuild/SPECS/
  tar czf ~/rpmbuild/SOURCES/coldfront-duckdb-extensions-${DUCKDB_EXT_VERSION}.tar.gz \
    -C /tmp "coldfront-duckdb-extensions-${DUCKDB_EXT_VERSION}"

  # This function is for debugging purpose if you have your own keys. GH workflow does not need it.
  #import_gpg_keys
}

build() {
  echo "Building RPM and SRPM..."
  QA_RPATHS=$(( 0xffff )) rpmbuild -ba ~/rpmbuild/SPECS/coldfront-duckdb-extensions.spec \
    --define "duckdb_ext_version ${DUCKDB_EXT_VERSION}" \
    --define "duckdb_ext_buildnum ${DUCKDB_EXT_BUILDNUM}" \
    --define "duckdb_version ${DUCKDB_VERSION}" \
    --define "duckdb_platform ${DUCKDB_PLATFORM}" \
    --define "extdir ${COLDFRONT_EXTDIR}"
}

post_build() {
  echo "📤 Copying built RPMs to /output..."
  mkdir -p /output
  cp -v ~/rpmbuild/RPMS/*/*.rpm /output/ || echo "No binary RPMs found"
  cp -v ~/rpmbuild/SRPMS/*.src.rpm /output/ || echo "No SRPM found"

  sign_rpms /output/*.rpm
  validate_signatures /output/*.rpm
}
