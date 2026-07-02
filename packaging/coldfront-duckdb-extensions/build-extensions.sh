#!/usr/bin/env bash
# build-extensions.sh — build the 4 patched ColdFront DuckDB extensions ONCE and
# stage them into <output-dir>. Arch-aware (linux_amd64 / linux_arm64), toolchain-
# agnostic: the CALLER installs the compiler/build tools (a modern C++ toolchain —
# gcc >= 14 — plus cmake/ninja/perl/vcpkg prerequisites). It is invoked:
#   * by release.yml's build-duckdb-ext job, inside a manylinux_2_28 container, so
#     the single binary is portable across every supported glibc (build-once), and
#   * by build-rpm.sh / build-deb.sh as a LOCAL fallback when no prebuilt artifact
#     has been staged.
#
# Usage: build-extensions.sh <output-dir>
#   Requires the component pins in the environment (ICEBERG_REPO/REF/BRANCH,
#   DUCKDB_VERSION/REPO, VCPKG_REPO); sources common.sh if they are unset.
set -euo pipefail

OUT_DIR="${1:?usage: build-extensions.sh <output-dir>}"
CWD="$(pwd)"                                    # repo root (build.sh cwd)
: "${COMPONENT_NAME:=packaging/coldfront-duckdb-extensions}"

# Pull in the build pins if we were invoked standalone (CI manylinux job).
if [ -z "${DUCKDB_VERSION:-}" ]; then
    # shellcheck disable=SC1090
    source "${CWD}/${COMPONENT_NAME}/common.sh"
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  DUCKDB_PLATFORM=linux_amd64; VCPKG_TRIPLET=x64-linux ;;
    aarch64) DUCKDB_PLATFORM=linux_arm64; VCPKG_TRIPLET=arm64-linux ;;
    *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

BUILD_ROOT="/tmp/cf-duckdb-ext-build"
ICE="${BUILD_ROOT}/duckdb-iceberg"

echo "Cloning + patching duckdb-iceberg (DuckDB v${DUCKDB_VERSION}, ${DUCKDB_PLATFORM})..."
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

# extension set (avro/azure/postgres_scanner refs) + the 4 ColdFront patches live
# in the repo's docker/ dir; git apply --check fails loudly on patch rot.
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
    # Activate gcc-toolset-14 if present (manylinux_2_28 / EL9); no-op elsewhere.
    # shellcheck disable=SC1090
    source /opt/rh/gcc-toolset-*/enable 2>/dev/null || true
    echo "-- compiler: $(gcc --version | head -1) --"
    export VCPKG_TOOLCHAIN_PATH="${BUILD_ROOT}/vcpkg/scripts/buildsystems/vcpkg.cmake"
    export VCPKG_ROOT="${BUILD_ROOT}/vcpkg"
    export VCPKG_TARGET_TRIPLET="$VCPKG_TRIPLET" VCPKG_HOST_TRIPLET="$VCPKG_TRIPLET"
    export USE_MERGED_VCPKG_MANIFEST=1
    export EXT_CONFIG="${ICE}/extension_config.cmake"
    # DuckDB stamps this as the engine version in the extension metadata footer;
    # it MUST match the loading engine (pg_duckdb's bundled DuckDB) exactly.
    export OVERRIDE_GIT_DESCRIBE="v${DUCKDB_VERSION}"
    # Cap parallelism to bound peak memory (DuckDB can OOM at high -j).
    export CMAKE_BUILD_PARALLEL_LEVEL=4
    make -j4 release
)

echo "Staging built extensions → ${OUT_DIR}"
mkdir -p "$OUT_DIR"
for e in iceberg avro azure postgres_scanner; do
    cp "${ICE}/build/release/extension/${e}/${e}.duckdb_extension" "$OUT_DIR/"
done
echo "Done. Built for ${DUCKDB_PLATFORM} (DuckDB v${DUCKDB_VERSION}):"
ls -la "$OUT_DIR"/*.duckdb_extension
