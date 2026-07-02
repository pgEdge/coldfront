#!/bin/bash
set -euo pipefail

RHEL="$(rpm --eval %rhel)"
CWD="$(pwd)"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  DUCKDB_PLATFORM=linux_amd64; VCPKG_TRIPLET=x64-linux ;;
  aarch64) DUCKDB_PLATFORM=linux_arm64; VCPKG_TRIPLET=arm64-linux ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

BUILD_ROOT="/tmp/cf-duckdb-ext-build"
ICE="${BUILD_ROOT}/duckdb-iceberg"
STAGE="/tmp/coldfront-duckdb-extensions-${DUCKDB_EXT_VERSION}"

prepare() {
  setup_dnf_build_env

  echo "Installing duckdb-iceberg build toolchain..."
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

  echo "Cloning + patching duckdb-iceberg (against DuckDB v${DUCKDB_VERSION})..."
  rm -rf "$BUILD_ROOT"; mkdir -p "$BUILD_ROOT"
  git clone --filter=blob:none --no-checkout "${ICEBERG_REPO}" "$ICE"
  git -C "$ICE" fetch --depth 80 origin "${ICEBERG_BRANCH}"
  git -C "$ICE" checkout "${ICEBERG_REF}"
  git -C "$ICE" submodule update --init --recursive --depth 1 --jobs 8
  # Pin the duckdb submodule to the engine version pg_duckdb links.
  rm -rf "$ICE/duckdb"
  git clone --depth 1 --branch "v${DUCKDB_VERSION}" --recurse-submodules "${DUCKDB_REPO}" "$ICE/duckdb"
  git clone "${VCPKG_REPO}" "${BUILD_ROOT}/vcpkg"
  "${BUILD_ROOT}/vcpkg/bootstrap-vcpkg.sh" -disableMetrics

  # extension set (avro/azure/postgres_scanner refs) + the 4 ColdFront patches
  # live in the repo's docker/ dir; git apply --check fails loudly on patch rot.
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
    # Activate gcc-toolset-14 on EL9 (gcc 14 for the C++ extensions); no-op on
    # EL10 / where the toolset is absent (native gcc used).
    # shellcheck disable=SC1090
    source /opt/rh/gcc-toolset-*/enable 2>/dev/null || true
    export VCPKG_TOOLCHAIN_PATH="${BUILD_ROOT}/vcpkg/scripts/buildsystems/vcpkg.cmake"
    export VCPKG_ROOT="${BUILD_ROOT}/vcpkg"
    export VCPKG_TARGET_TRIPLET="$VCPKG_TRIPLET" VCPKG_HOST_TRIPLET="$VCPKG_TRIPLET"
    export USE_MERGED_VCPKG_MANIFEST=1
    export EXT_CONFIG="${ICE}/extension_config.cmake"
    export OVERRIDE_GIT_DESCRIBE="v${DUCKDB_VERSION}"
    # Cap parallelism to bound peak memory (DuckDB can OOM at high -j); matches
    # pg_duckdb and keeps a single cell within a GitHub runner / the Docker VM.
    export CMAKE_BUILD_PARALLEL_LEVEL=4
    make -j4 release
  )

  echo "Staging built extensions + docs for packaging..."
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  for e in iceberg avro azure postgres_scanner; do
    cp "${ICE}/build/release/extension/${e}/${e}.duckdb_extension" "$STAGE/"
  done
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
