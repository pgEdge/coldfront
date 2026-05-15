###
### STAGE 1 — base build env + stock pg_duckdb v1.1.1.
###
### ColdFront's own build is split into its own stage below so that
### editing coldfront .c / .sql does NOT invalidate the (hot) base
### cache. iceberg + avro are NOT compiled here — they're downloaded
### per-session from extensions.duckdb.org by pg_duckdb via the
### duckdb.install_extension('iceberg') call (signed upstream
### binaries; the iceberg init transitively pulls avro the same way).
### Decoupling parquet upload from the bakery claim does NOT require
### patching duckdb-iceberg: pg_duckdb's XactCallback defers the
### iceberg commit POST to PG PRE_COMMIT, so duckdb.raw_query()
### returns BEFORE the POST fires — coldfront just claims the bakery
### between raw_query() return and the implicit PG commit.
###
FROM ghcr.io/pgedge/pgedge-postgres:17.9-spock5.0.7-standard AS base

USER root
# Package list kept identical to earlier builds to keep the dnf-install
# layer's cache hit (and thus the cached pg_duckdb compile underneath).
# gcc-toolset-13 + perl-* are not needed now that we no longer compile
# duckdb-iceberg locally, but removing them would invalidate the
# expensive cached layer. Acceptable extra image-build-time fat.
RUN dnf install -y --setopt=install_weak_deps=False \
        pgedge-postgresql17-devel \
        gcc gcc-c++ make cmake ninja-build ccache git clang llvm \
        gcc-toolset-13 gcc-toolset-13-libstdc++-devel \
        flex bison redhat-rpm-config \
        readline-devel zlib-devel openssl-devel \
        libxml2-devel libxslt-devel \
        libcurl-devel lz4-devel glib2-devel libicu-devel \
        pkgconf-pkg-config libstdc++-devel \
        perl-IPC-Cmd zip unzip tar autoconf automake libtool python3 ninja-build \
        perl perl-core perl-FindBin perl-File-Compare perl-File-Copy perl-FileHandle \
        perl-Pod-Html perl-Digest-SHA \
    && dnf clean all

ENV PATH=/usr/pgsql-17/bin:$PATH
ENV PG_CONFIG=/usr/pgsql-17/bin/pg_config

WORKDIR /build
RUN git clone --depth 1 --branch v1.1.1 --recurse-submodules --shallow-submodules \
        https://github.com/duckdb/pg_duckdb /build/pg_duckdb

# pgEdge PG 17 propagates -fexcess-precision=standard into CXXFLAGS, which gcc
# rejects for C++. Strip it after PGXS is included.
RUN printf '\noverride CXXFLAGS := $(filter-out -fexcess-precision=standard,$(CXXFLAGS))\n' \
        >> /build/pg_duckdb/Makefile.global

RUN make -C /build/pg_duckdb -j"$(nproc)" \
 && DESTDIR=/out make -C /build/pg_duckdb install

###
### STAGE 2 — coldfront C+SQL extension build.
###
### Parent is `base` so this stage runs INDEPENDENTLY. Editing
### extension/coldfront/* only invalidates this stage; the pg_duckdb
### compile in `base` stays cached.
###
FROM base AS coldfront-builder

COPY --chown=root:root extension/coldfront /build/coldfront
RUN DESTDIR=/out make -C /build/coldfront install

###
### RUNTIME
###
FROM ghcr.io/pgedge/pgedge-postgres:17.9-spock5.0.7-standard

USER root
RUN dnf install -y --setopt=install_weak_deps=False --allowerasing libcurl lz4 \
    && dnf clean all

# pg_duckdb (compiled in stage `base`)
COPY --from=base                /out/usr/pgsql-17/lib/             /usr/pgsql-17/lib/
COPY --from=base                /out/usr/pgsql-17/share/extension/ /usr/pgsql-17/share/extension/
# coldfront C+SQL extension (compiled in stage `coldfront-builder`)
COPY --from=coldfront-builder   /out/usr/pgsql-17/lib/             /usr/pgsql-17/lib/
COPY --from=coldfront-builder   /out/usr/pgsql-17/share/extension/ /usr/pgsql-17/share/extension/

COPY docker/coldfront-spock-entrypoint.sh /usr/local/bin/coldfront-spock-entrypoint.sh
RUN chmod +x /usr/local/bin/coldfront-spock-entrypoint.sh

# docker-compose.distributed.yml overrides PGDATA to /data/pgdata and
# mounts a named volume at /data. The base image runs as the postgres
# user (uid 26), so /data must be created up-front with that ownership.
RUN mkdir -p /data && chown postgres:postgres /data

USER postgres
ENTRYPOINT ["/usr/local/bin/coldfront-spock-entrypoint.sh"]
