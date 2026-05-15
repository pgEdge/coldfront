FROM pgduckdb/pgduckdb:18-v1.1.1

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
        postgresql-server-dev-18 gcc make \
    && rm -rf /var/lib/apt/lists/*

COPY extension/coldfront /build/coldfront
RUN make -C /build/coldfront install && rm -rf /build
