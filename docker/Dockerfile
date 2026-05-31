# Parameterized ColdFront image — ONE build serving every matrix cell.
#
#   docker build -f docker/Dockerfile --build-arg PG_MAJOR=18 -t coldfront:pg18 .
#   PG_MAJOR ∈ {16,17,18}
#
# Base is the pgEdge "minimal" image (bundles Spock + Snowflake but NOT
# pg_duckdb, which we compile from stock upstream v1.1.1). The SAME image plays
# both topology roles: vanilla leaves spock/snowflake out of
# shared_preload_libraries (entrypoint default), mesh loads them (MESH=on).
# This replaces the two former Dockerfiles (coldfront.Dockerfile +
# coldfront-spock.Dockerfile) with one parameterized build.
#
# iceberg + avro are NOT compiled here — pg_duckdb auto-installs them per
# session from extensions.duckdb.org (signed upstream binaries) via the
# ATTACH (TYPE ICEBERG, ...) path, gated by duckdb.autoinstall/autoload (set
# in the entrypoint).
ARG PG_MAJOR=18
ARG PGEDGE_TAG=${PG_MAJOR}-spock5-minimal

# ─── build stage: compile pg_duckdb v1.1.1 + the coldfront extension ─────────
FROM ghcr.io/pgedge/pgedge-postgres:${PGEDGE_TAG} AS build
ARG PG_MAJOR
USER root
# Build toolchain + link-time devel libs. The minimal base ships dnf + the
# pgedge repo but no compiler; pgedge-postgresql${PG_MAJOR}-devel provides the
# server headers / PGXS. Build-stage size is irrelevant (artifacts are copied
# into a fresh runtime stage below).
RUN dnf install -y --setopt=install_weak_deps=False \
        pgedge-postgresql${PG_MAJOR}-devel \
        gcc gcc-c++ make cmake ninja-build git \
        redhat-rpm-config \
        openssl-devel libcurl-devel lz4-devel zlib-devel libicu-devel \
        pkgconf-pkg-config python3 \
    && dnf clean all

ENV PATH=/usr/pgsql-${PG_MAJOR}/bin:$PATH
ENV PG_CONFIG=/usr/pgsql-${PG_MAJOR}/bin/pg_config

WORKDIR /build
RUN git clone --depth 1 --branch v1.1.1 --recurse-submodules --shallow-submodules \
        https://github.com/duckdb/pg_duckdb /build/pg_duckdb

# pgEdge propagates -fexcess-precision=standard into CXXFLAGS, which gcc
# rejects for C++. Strip it after PGXS is included (no-op if absent).
RUN printf '\noverride CXXFLAGS := $(filter-out -fexcess-precision=standard,$(CXXFLAGS))\n' \
        >> /build/pg_duckdb/Makefile.global

# with_llvm=no skips PG's JIT-bitcode (.bc) emission + llvm-lto link. pg_duckdb
# executes inside DuckDB, so PG-side JIT inlining of its functions is irrelevant
# — and this sidesteps having to match the exact versioned LLVM toolchain the
# pgEdge server was built with (llvm20 for PG18, etc.), keeping the build
# uniform across PG majors.
RUN make -C /build/pg_duckdb -j"$(nproc)" with_llvm=no \
 && DESTDIR=/out make -C /build/pg_duckdb install with_llvm=no

# diffutils: pg_regress needs `diff` to compare expected vs actual output when
# this build stage is reused to run the unit layer (ci/topo/vanilla.sh
# --regress). Installed after the compile so it doesn't bust the compile cache.
RUN dnf install -y --setopt=install_weak_deps=False diffutils && dnf clean all

COPY extension/coldfront /build/coldfront
RUN DESTDIR=/out make -C /build/coldfront install with_llvm=no

# ─── iceberg-builder stage: compile PATCHED duckdb-iceberg + avro ────────────
# Separate toolchain (manylinux gcc-toolset-14 — sidesteps a GCC-11 avro bug;
# see PATCHED.md). Builds the bakery-aware-commit-refresh patch ONLY — the
# mvcc-fix patch breaks commit on pg_duckdb v1.1.1. Output is a DuckDB v1.4.3
# ABI extension, copied into the runtime stage and loaded as unsigned so the
# mesh bakery can overlap parquet uploads (coldfront.iceberg_async_parquet=on).
FROM quay.io/pypa/manylinux_2_28_x86_64 AS iceberg-builder
ARG ICEBERG_REF=ebe0dfaf
RUN dnf install -y --setopt=install_weak_deps=False \
        ninja-build perl-IPC-Cmd ccache jq wget zip unzip tar autoconf libtool kernel-headers cmake git make \
    && dnf clean all
WORKDIR /build
RUN git clone --filter=blob:none --no-checkout https://github.com/duckdb/duckdb-iceberg \
 && git -C duckdb-iceberg checkout ${ICEBERG_REF} \
 && git -C duckdb-iceberg submodule update --init --recursive --depth 1 --jobs 8 \
 && git clone https://github.com/microsoft/vcpkg /build/vcpkg \
 && /build/vcpkg/bootstrap-vcpkg.sh
# Slim build config + the bakery patch, COPY'd AFTER the heavy clone/vcpkg layer
# so editing them doesn't bust it. git apply --check fails the build loudly on
# patch rot instead of silently shipping a stock extension.
COPY docker/iceberg-only-extension-config.cmake       /build/duckdb-iceberg/extension_config.cmake
COPY docker/iceberg-bakery-aware-commit-refresh.patch /tmp/iceberg-bakery.patch
RUN cd /build/duckdb-iceberg \
 && git apply --check /tmp/iceberg-bakery.patch \
 && git apply        /tmp/iceberg-bakery.patch
RUN cd /build/duckdb-iceberg && bash -c 'source /opt/rh/gcc-toolset-*/enable 2>/dev/null; \
    export VCPKG_TOOLCHAIN_PATH=/build/vcpkg/scripts/buildsystems/vcpkg.cmake VCPKG_ROOT=/build/vcpkg \
           VCPKG_TARGET_TRIPLET=x64-linux VCPKG_HOST_TRIPLET=x64-linux USE_MERGED_VCPKG_MANIFEST=1 \
           EXT_CONFIG=/build/duckdb-iceberg/extension_config.cmake OVERRIDE_GIT_DESCRIBE=v1.4.3 \
           CMAKE_BUILD_PARALLEL_LEVEL=$(nproc); \
    make -j$(nproc) release'

# ─── runtime stage: minimal base + the compiled artifacts ────────────────────
FROM ghcr.io/pgedge/pgedge-postgres:${PGEDGE_TAG}
ARG PG_MAJOR
USER root
# Runtime shared libs pg_duckdb links (httpfs/curl, lz4) + contrib for dblink.
# The mesh role's R-A bakery uses dblink for its autonomous claim/release
# transaction, and dblink ships only in the contrib package. One image serves
# both roles, so it carries dblink unconditionally (vanilla simply never loads
# it). uuid-ossp also comes with contrib but is unused — ColdFront uses the core
# `uuid` type and Lakekeeper runs its catalog on its own dedicated Postgres.
RUN dnf install -y --setopt=install_weak_deps=False --allowerasing \
        libcurl lz4 pgedge-postgresql${PG_MAJOR}-contrib \
    && dnf clean all

COPY --from=build /out/usr/pgsql-${PG_MAJOR}/lib/             /usr/pgsql-${PG_MAJOR}/lib/
COPY --from=build /out/usr/pgsql-${PG_MAJOR}/share/extension/ /usr/pgsql-${PG_MAJOR}/share/extension/

# Patched duckdb-iceberg + avro (bakery-aware commit refresh), staged in the
# image. The entrypoint copies these into $PGDATA/pg_duckdb/extensions/<ver>/
# <platform>/ on first init and sets allow_unsigned + iceberg_async_parquet so
# the mesh bakery overlaps parquet uploads. See PATCHED.md.
COPY --from=iceberg-builder /build/duckdb-iceberg/build/release/extension/iceberg/iceberg.duckdb_extension /opt/coldfront/iceberg/iceberg.duckdb_extension
COPY --from=iceberg-builder /build/duckdb-iceberg/build/release/extension/avro/avro.duckdb_extension       /opt/coldfront/iceberg/avro.duckdb_extension
ENV COLDFRONT_DUCKDB_VERSION=v1.4.3 \
    COLDFRONT_DUCKDB_PLATFORM=linux_amd64

COPY docker/entrypoint.sh /usr/local/bin/coldfront-entrypoint.sh
RUN chmod +x /usr/local/bin/coldfront-entrypoint.sh

# A compose may override PGDATA onto a mounted volume; create it owned by the
# postgres runtime user (matches the pgEdge base's uid).
RUN mkdir -p /data && chown postgres:postgres /data

ENV PG_MAJOR=${PG_MAJOR}
USER postgres
ENTRYPOINT ["/usr/local/bin/coldfront-entrypoint.sh"]
