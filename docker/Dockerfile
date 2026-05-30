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

# ─── runtime stage: minimal base + the compiled artifacts ────────────────────
FROM ghcr.io/pgedge/pgedge-postgres:${PGEDGE_TAG}
ARG PG_MAJOR
USER root
# Runtime shared libs pg_duckdb links (httpfs/curl, lz4). No contrib: ColdFront
# uses the core `uuid` type (not uuid-ossp), and Lakekeeper runs its catalog on
# its own dedicated Postgres (see docker-compose). The mesh role's dblink need
# is handled when the mesh cell is built, not speculatively here.
RUN dnf install -y --setopt=install_weak_deps=False --allowerasing libcurl lz4 \
    && dnf clean all

COPY --from=build /out/usr/pgsql-${PG_MAJOR}/lib/             /usr/pgsql-${PG_MAJOR}/lib/
COPY --from=build /out/usr/pgsql-${PG_MAJOR}/share/extension/ /usr/pgsql-${PG_MAJOR}/share/extension/

COPY docker/entrypoint.sh /usr/local/bin/coldfront-entrypoint.sh
RUN chmod +x /usr/local/bin/coldfront-entrypoint.sh

# A compose may override PGDATA onto a mounted volume; create it owned by the
# postgres runtime user (matches the pgEdge base's uid).
RUN mkdir -p /data && chown postgres:postgres /data

ENV PG_MAJOR=${PG_MAJOR}
USER postgres
ENTRYPOINT ["/usr/local/bin/coldfront-entrypoint.sh"]
