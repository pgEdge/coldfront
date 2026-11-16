# Installing ColdFront

This guide details installing ColdFront with a pgEdge package or
building it from source. After installing ColdFront, see
[Configuring ColdFront](configuration.md) for detailed information about
setting up PostgreSQL, Lakekeeper, and ColdFront itself.

## Using a Package to Install ColdFront

ColdFront's packages come from the pgEdge package repository. Before you
install the packages, set up access to the repository:

1. Request and install a certificate from pgEdge, as described in the
   [pgEdge Enterprise Postgres documentation](https://docs.pgedge.com/enterprise/).
2. Configure the pgEdge repository by following the steps in the Enterprise
   Postgres documentation:

    - For RHEL, Oracle Linux, AlmaLinux, and Rocky Linux, see
      [Configuring the Repository on Enterprise Linux](https://docs.pgedge.com/enterprise/el/configure-repo/).
    - For Debian and Ubuntu, see
      [Configuring the Repository on Debian and Ubuntu](https://docs.pgedge.com/enterprise/debian/configure-repo/).

If you already have a PostgreSQL server installed that you would like to use,
configure the pgEdge repository and install only ColdFront, continuing with
[Installing the ColdFront Packages](#installing-the-coldfront-packages).
ColdFront packages from pgEdge require pgEdge's PostgreSQL build.

### Installing PostgreSQL with Packages

After you configure the pgEdge repository, install pgEdge Enterprise Postgres
and start the server. The following steps walk you through the installation:

1. Install pgEdge Enterprise Postgres. On RHEL, Rocky Linux, or AlmaLinux, the
   package does not create a database cluster, so the installation is followed
   by commands that create and start the cluster:

    ```bash
    sudo dnf install -y pgedge-enterprise-postgres_18
    sudo /usr/pgsql-18/bin/postgresql-18-setup initdb
    sudo systemctl enable --now postgresql-18
    ```

    On Ubuntu or Debian, install the package, then check for a cluster with
    `sudo pg_lsclusters`:

    ```bash
    sudo apt update
    sudo apt install -y pgedge-enterprise-postgres-18
    sudo pg_lsclusters
    ```

2. Confirm that the server is running before you continue:

    ```bash
    sudo -u postgres psql -c "SELECT version();"
    ```

    The command displays the PostgreSQL version. If the server is not running
    and `sudo pg_lsclusters` lists no `18/main` cluster, use the following
    command to create and start the cluster:

    ```bash
    sudo pg_createcluster 18 main --start
    ```

    !!! hint

        A connection error means the server is not running; check
        `sudo systemctl status postgresql-18` on RHEL-family systems or
        `sudo pg_lsclusters` on Ubuntu and Debian.

For details, see the pgEdge Enterprise Postgres installation guide for
[Enterprise Linux](https://docs.pgedge.com/enterprise/el/installing/) or
[Debian and Ubuntu](https://docs.pgedge.com/enterprise/debian/installing/).

### Installing the ColdFront Packages

With PostgreSQL running, install the ColdFront packages for your PostgreSQL
major version:

1. Install the ColdFront extension. On RHEL, Rocky Linux, or AlmaLinux, use
   the command:

    ```bash
    sudo dnf install -y pgedge-coldfront_18
    ```

    On Ubuntu or Debian, use the command:

    ```bash
    sudo apt install -y pgedge-postgresql-18-coldfront
    ```

    For another PostgreSQL major version, replace `18` in the package name
    with that version.

2. Install the ColdFront command-line tools and the Lakekeeper catalog. On
   RHEL, Rocky Linux, or AlmaLinux, use the command:

    ```bash
    sudo dnf install -y pgedge-coldfront pgedge-lakekeeper
    ```

    On Ubuntu or Debian, use the command:

    ```bash
    sudo apt install -y pgedge-coldfront pgedge-lakekeeper
    ```

The `pgedge-lakekeeper` package installs Lakekeeper but does not start it; you
configure and start it as described in
[Configuring Lakekeeper](configure_lakekeeper.md).

!!! hint

    The ColdFront extension package depends on pg_duckdb and ColdFront's
    DuckDB extensions, so the package manager installs them as well. Both are
    patched builds rather than the upstream releases; they include ColdFront's
    patches to duckdb-iceberg, pg_duckdb, and DuckDB.
    [Understanding ColdFront's DuckDB Stack](#understanding-coldfronts-duckdb-stack)
    describes each patch and why ColdFront applies it.

## Building ColdFront from Source on Bare Metal

Before you build ColdFront on bare metal, make sure that you have the
following:

- A PostgreSQL 16, 17, or 18 server.
- `pg_config` and the PostgreSQL server development headers.
- The libpq client headers and library (`libpq-dev` or `libpq-devel`).
- `make` and `gcc`.
- Go 1.26.10 or later (pinned in
  [go.mod](https://github.com/pgEdge/ColdFront/blob/main/go.mod)), to build the
  archiver and the partitioner; `make build` produces `./bin/archiver` and
  `./bin/partitioner`.
- golangci-lint, to build the compactor with `make compactor`.

### Preparing pg_duckdb and the DuckDB Extensions

When the prerequisites are in place, start by building and installing pg_duckdb
on DuckDB 1.5.4 and the patched DuckDB extensions, with the patches that
[Understanding ColdFront's DuckDB Stack](#understanding-coldfronts-duckdb-stack)
describes. The following steps reproduce the compile steps in
[`docker/Dockerfile.duckdb15-base`](https://github.com/pgEdge/ColdFront/blob/main/docker/Dockerfile.duckdb15-base)
on a RHEL-family host running PostgreSQL 18; adjust the package names and the
PostgreSQL major version for your system.

1. Install the build tools and libraries:

    ```bash
    sudo dnf install -y pgedge-postgresql18-devel gcc gcc-c++ make cmake \
      ninja-build git redhat-rpm-config openssl-devel libcurl-devel \
      lz4-devel zlib-devel libicu-devel pkgconf-pkg-config python3 \
      perl-IPC-Cmd flex bison autoconf libtool zip unzip wget tar
    export PATH=/usr/pgsql-18/bin:$PATH
    export PG_CONFIG=/usr/pgsql-18/bin/pg_config
    ```

    !!! hint

        DuckDB 1.5.4 needs libcurl 7.77 or later to compile. Run
        `curl-config --version` to check the installed version. On a system
        with an older version, the following script installs libcurl 8.12.0
        under `/usr/local`, leaving the system libcurl in place, and makes the
        newer version available to the build and to PostgreSQL:

        ```bash
        wget https://curl.se/download/curl-8.12.0.tar.gz
        tar xf curl-8.12.0.tar.gz && cd curl-8.12.0
        ./configure --with-openssl --prefix=/usr/local --disable-static \
          --without-libpsl --without-libssh2 --without-nghttp2 \
          --without-brotli --without-zstd
        make -j"$(nproc)" && sudo make install
        echo /usr/local/lib | sudo tee /etc/ld.so.conf.d/curl-local.conf
        sudo ldconfig
        export PATH=/usr/local/bin:$PATH
        export CMAKE_PREFIX_PATH=/usr/local
        cd ..
        ```

2. Clone the ColdFront repository, which holds the patch files in its `docker`
   directory, and set `COLDFRONT_SRC` to the location of the copy:

    ```bash
    git clone https://github.com/pgEdge/ColdFront "$HOME/coldfront"
    export COLDFRONT_SRC=$HOME/coldfront
    ```

3. Fetch pg_duckdb at the pinned commit, apply ColdFront's `EXTRACT`
   field-quoting patch to pg_duckdb (see
   [Patching pg_duckdb](#patching-pg_duckdb)) and its brotli patch to the DuckDB
   that pg_duckdb compiles (see [Patching DuckDB](#patching-duckdb)), and then
   build and install pg_duckdb:

    ```bash
    git clone https://github.com/duckdb/pg_duckdb && cd pg_duckdb
    git checkout c04e6a2dcf4e999abb921da1ba2f8335dad644e0
    git submodule update --init --recursive
    git apply "$COLDFRONT_SRC/docker/pg_duckdb-extract-field-quoting.patch" &&
      git -C third_party/duckdb apply \
        "$COLDFRONT_SRC/docker/duckdb-brotli-block-switch-v15.patch" &&
      make -j"$(nproc)" with_llvm=no &&
      sudo make install with_llvm=no PG_CONFIG="$PG_CONFIG"
    cd ..
    ```

    The `&&` operators chain the patch, build, and install commands, so if
    either patch fails to apply, pg_duckdb is not built or installed.

    If the compiler rejects `-fexcess-precision=standard` for C++, append the
    line
    `override CXXFLAGS := $(filter-out -fexcess-precision=standard,$(CXXFLAGS))`
    to `pg_duckdb/Makefile.global` and run `make` again.

4. Fetch duckdb-iceberg at the pinned commit, replace its DuckDB submodule with
   DuckDB 1.5.4, and set up vcpkg:

    ```bash
    git clone https://github.com/duckdb/duckdb-iceberg && cd duckdb-iceberg
    git checkout 5edc45f0
    git submodule update --init --recursive
    rm -rf duckdb
    git clone --depth 1 --branch v1.5.4 --recurse-submodules \
      https://github.com/duckdb/duckdb duckdb
    git clone https://github.com/microsoft/vcpkg ../vcpkg
    ../vcpkg/bootstrap-vcpkg.sh -disableMetrics
    cp "$COLDFRONT_SRC/docker/iceberg-azure-extension-config-v15.cmake" \
      extension_config.cmake
    ```

5. Apply ColdFront's duckdb-iceberg patches in the following order;
   [Patching duckdb-iceberg](#patching-duckdb-iceberg) describes each patch:

    ```bash
    (
      for p in iceberg-bakery-aware-commit-refresh-v15 \
               iceberg-manifest-list-format-version-v15 \
               iceberg-data-file-format-v15 \
               iceberg-timestamptz-utc-transforms-v15 \
               iceberg-schema-id-allocation-v15 \
               iceberg-vended-secret-keep-v15 \
               iceberg-manifest-read-error-v15; do
        git apply "$COLDFRONT_SRC/docker/$p.patch" ||
          { echo "failed: $p"; exit 1; }
      done
    )
    ```

    The parentheses run the loop in a subshell, so a failed patch stops the
    loop with a nonzero status without closing your terminal. If a patch
    fails, fix it before you continue to the next step.

6. Build the iceberg, avro, azure, and postgres_scanner extensions:

    ```bash
    case "$(uname -m)" in
      x86_64)  VCPKG_TRIPLET=x64-linux ;;
      aarch64) VCPKG_TRIPLET=arm64-linux ;;
    esac
    export VCPKG_ROOT=$PWD/../vcpkg
    export VCPKG_TOOLCHAIN_PATH=$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake
    export VCPKG_TARGET_TRIPLET=$VCPKG_TRIPLET VCPKG_HOST_TRIPLET=$VCPKG_TRIPLET
    export USE_MERGED_VCPKG_MANIFEST=1
    export EXT_CONFIG=$PWD/extension_config.cmake
    export OVERRIDE_GIT_DESCRIBE=v1.5.4
    make -j"$(nproc)" release
    ```

7. Copy the built extensions into the pg_duckdb extension directory under the
   PostgreSQL data directory, as
   [`docker/entrypoint.sh`](https://github.com/pgEdge/ColdFront/blob/main/docker/entrypoint.sh)
   does. Set `PGDATA` to your data directory:

    ```bash
    case "$(uname -m)" in
      x86_64)  DUCKDB_PLATFORM=linux_amd64 ;;
      aarch64) DUCKDB_PLATFORM=linux_arm64 ;;
    esac
    EXTDIR="$PGDATA/pg_duckdb/extensions/v1.5.4/$DUCKDB_PLATFORM"
    sudo -u postgres mkdir -p "$EXTDIR"
    for e in iceberg avro azure postgres_scanner; do
      sudo install -o postgres -g postgres -m 644 \
        "build/release/extension/$e/$e.duckdb_extension" "$EXTDIR/"
    done
    ```

### Building and Configuring the ColdFront Extension

Then, after you prepare pg_duckdb and the DuckDB extensions, use the following
steps to build, install, and configure the `coldfront` extension, which is a
standard PGXS C extension:

1. Build and install the extension:

    ```bash
    cd "$COLDFRONT_SRC/extension/coldfront"
    make                # needs pg_config and the PostgreSQL server dev headers on PATH
    sudo make install PG_CONFIG="$(command -v pg_config)"
    ```

2. Set the following parameters in `postgresql.conf`:

    ```ini
    shared_preload_libraries = 'pg_duckdb,coldfront'
    # The locally built iceberg extension is unsigned.
    duckdb.allow_unsigned_extensions = true
    duckdb.autoinstall_known_extensions = false
    duckdb.postgres_role          = 'coldfront_duckdb'
    coldfront.warehouse           = '<warehouse-name>'
    coldfront.lakekeeper_endpoint = 'http://<lakekeeper-host>:8181/catalog'
    coldfront.local_pg_dsn        = 'host=/var/run/postgresql dbname=<db> user=<role>'
    # Optional, and only with the patched duckdb-iceberg: async cold-write ordering.
    coldfront.iceberg_async_parquet = on
    coldfront.iceberg_bakery_patch  = on
    ```

3. Restart PostgreSQL so that the server loads pg_duckdb and ColdFront:

    ```bash
    sudo systemctl restart postgresql-18
    ```

    !!! hint

        ColdFront loads only through `shared_preload_libraries`. On a server that
        does not preload it, `CREATE EXTENSION coldfront` fails with the error
        `coldfront must be loaded via shared_preload_libraries`; add `coldfront`
        after `pg_duckdb` in that setting and restart the server.

4. Create the `coldfront_duckdb` role that `duckdb.postgres_role` names. Only
   members of that role can use DuckDB; if you leave the parameter out, only
   superusers can use DuckDB, and `coldfront.grant_app_access()` returns an
   error. Create the role before you grant access to an application role:

    ```sql
    CREATE ROLE coldfront_duckdb NOLOGIN;
    ```

See the [Configuring PostgreSQL](configuration.md#configuring-postgresql)
section of the Configuring ColdFront guide for the remaining parameters, and
[Connecting to ColdFront](connecting.md) for granting application roles access
with `coldfront.grant_app_access()`.

## Building ColdFront from Source on Docker

!!! warning

    The Docker image is built for development and testing. Its `pg_hba.conf`
    trusts every connection from any address without a password, so do not
    expose the containers to an untrusted network.

Before you build ColdFront on Docker, make sure that you have the following:

- Docker.
- Network access to GitHub, ghcr.io, quay.io, curl.se, and the distribution's
  RPM repositories.
- A few GB of disk space and RAM, and 30 to 60 minutes for the base compile.
- Go 1.26.10 or later (pinned in
  [go.mod](https://github.com/pgEdge/ColdFront/blob/main/go.mod)) and `make`,
  to build the archiver and the partitioner; `make build` produces
  `./bin/archiver` and `./bin/partitioner`.
- golangci-lint, to build the compactor with `make compactor`.

### Preparing the DuckDB Base Image

When the prerequisites are in place, start with the DuckDB base image, which
holds the components that take longest to compile.
[`docker/Dockerfile.duckdb15-base`](https://github.com/pgEdge/ColdFront/blob/main/docker/Dockerfile.duckdb15-base)
contains the recipe for the base image: it fetches the requirements, applies
the ColdFront patches that [Understanding ColdFront's DuckDB
Stack](#understanding-coldfronts-duckdb-stack) describes, and compiles a set of
components. The following table shows each component and its source:

| Component | Source |
|---|---|
| libcurl 8.12.0 | The recipe builds libcurl from source from `curl.se`, because DuckDB 1.5.4 httpfs needs curl 7.77 or later at compile time and the pgEdge base ships 7.76.1. |
| pg_duckdb (DuckDB 1.5.4) | `github.com/duckdb/pg_duckdb`, PR #1025, with ColdFront's `EXTRACT` field-quoting patch applied, and with ColdFront's brotli patch applied to the DuckDB it compiles |
| duckdb-iceberg | `github.com/duckdb/duckdb-iceberg`, `v1.5-variegata` @ `5edc45f0` |
| DuckDB 1.5.4 | `github.com/duckdb/duckdb`, tag `v1.5.4`, which replaces duckdb-iceberg's own DuckDB submodule |
| duckdb-avro, duckdb-azure, duckdb-postgres | `github.com/duckdb/duckdb-avro` @ `7f423d69`, `github.com/duckdb/duckdb-azure` @ `563589b2`, and `github.com/duckdb/duckdb-postgres` @ `4053b617`, pinned in `docker/iceberg-azure-extension-config-v15.cmake` |
| vcpkg | `github.com/microsoft/vcpkg` |
| Base images | `ghcr.io/pgedge/pgedge-postgres:<pg>-spock5-minimal` and `quay.io/pypa/manylinux_2_28_<arch>` |

The base image is built in three Docker stages:

1. The first stage builds libcurl, patches pg_duckdb and its bundled copy of
   DuckDB, and then builds pg_duckdb.
2. The second stage clones duckdb-iceberg at the pinned commit, applies
   ColdFront's patches (see [Patching duckdb-iceberg](#patching-duckdb-iceberg)),
   and compiles the iceberg, avro, azure, and postgres_scanner extensions with
   vcpkg.
3. The third stage assembles the runtime image.

The build checks that each patch applies cleanly before applying it. If a patch
no longer applies, the build stops with an error instead of producing an image
with an unpatched duckdb-iceberg. An unpatched duckdb-iceberg fails with HTTP
409 errors under concurrent writes and writes manifests that strict Apache
Iceberg readers reject.

!!! note "pg_duckdb pin"

    The base pins pg_duckdb to the merged PR #1025 commit `c04e6a2` (DuckDB
    1.5.4 - its duckdb submodule is the v1.5.4 tag), a fixed commit for
    reproducible builds rather than a moving PR head.

!!! note "Base foundation"

    The base is `FROM ghcr.io/pgedge/pgedge-postgres:<pg>-spock5-minimal`; you
    need pull access to that image (or substitute an equivalent PostgreSQL base
    with the same layout).

### Building and Starting the ColdFront Containers

Then, build the base image and start the ColdFront containers. Docker Compose
builds the ColdFront PostgreSQL image and starts it with Lakekeeper, the
database that Lakekeeper stores its catalog in, and, with the `local-store`
profile, a SeaweedFS object store for testing. Together, these containers make
up the ColdFront stack.

The build runs in two stages. Splitting it keeps the slow compiles in a base
image that rarely changes, so rebuilding ColdFront itself takes seconds and
always uses the current source:

1. Clone the ColdFront repository, change to its directory, and set
   `PG_MAJOR` to the PostgreSQL major version to build, 16, 17, or 18:

    ```bash
    git clone https://github.com/pgEdge/ColdFront coldfront && cd coldfront
    export PG_MAJOR=18
    ```

    The later commands in this section and in
    [Verifying the Build](#verifying-the-build) read `PG_MAJOR`, so run them in
    the same shell.

2. Build the base image, which compiles pg_duckdb on DuckDB 1.5.4 and the
   patched duckdb-iceberg that
   [Understanding ColdFront's DuckDB Stack](#understanding-coldfronts-duckdb-stack)
   describes. The build takes 30 to 60 minutes and needs network access and a
   few GB of disk space and RAM. The build installs from the pgEdge package
   repositories, so the command passes your repository client certificate and
   key, `client.crt` and `client.key` at the repo root, as build secrets; the
   build never stores them in the image:

    ```bash
    docker build -f docker/Dockerfile.duckdb15-base \
      --build-arg PG_MAJOR="$PG_MAJOR" \
      --secret id=repo_client_crt,src=client.crt \
      --secret id=repo_client_key,src=client.key \
      -t "ghcr.io/pgedge/coldfront-duckdb-base:pg$PG_MAJOR" .
    ```

    pgEdge also publishes the base image as
    `ghcr.io/pgedge/coldfront-duckdb-base:pg16`, `:pg17`, and `:pg18`. If you
    skip this step, the next step uses the published image.

3. Build the app image and start the stack. The app image, built from
   [`docker/Dockerfile.duckdb15`](https://github.com/pgEdge/ColdFront/blob/main/docker/Dockerfile.duckdb15),
   starts from your local base image if you built one in step 2, or from the
   published image otherwise, and compiles only the `coldfront` extension.
   The app build also installs from the pgEdge package repositories, so place
   your repository client certificate and key at the repo root as `client.crt`
   and `client.key`, or set `REPO_CLIENT_CRT` and `REPO_CLIENT_KEY` to their
   paths; the build mounts them as secrets and never stores them in the image.
   If either file is outside the repo (including through a symlink), also run
   `export BUILDX_BAKE_ENTITLEMENTS_FS=0`, because Compose will not otherwise
   read it. The commands publish each port on the loopback address only,
   because the PostgreSQL server trusts every connection and Lakekeeper runs
   without authentication:

    ```bash
    export COLDFRONT_PG_PORT=127.0.0.1:5432 COLDFRONT_LK_PORT=127.0.0.1:8181 \
      COLDFRONT_S3_PORT=127.0.0.1:8333
    docker compose up -d --build
    ```

    Compose builds the app image for the version in `PG_MAJOR`. The exported
    port variables apply to every later Compose command in the same shell,
    including the commands in [Verifying the Build](#verifying-the-build).
    Without them, Compose publishes the ports on every network interface. The command starts a single-node stack for one
    host. The repository's other Compose files, `docker-compose.matrix.yml`
    and `docker-compose.mesh.yml`, are for CI rather than for end-user setups.

### Using Environment Variables

After the stack is running, you can change how the ColdFront container starts
with environment variables. The entrypoint reads the following variables when
the container starts. It writes the server settings they control into
`postgresql.conf` only when the data directory is empty, so a change to one of
them takes effect on a fresh volume or after editing `postgresql.conf` by hand.
The following table describes each variable:

| Variable | Default | Effect |
|----------|---------|--------|
| `PG_MAJOR` | set by the image | The PostgreSQL major version that the entrypoint starts. The image sets this variable from the `PG_MAJOR` build argument, so any value you set when you run the container must match the version the image was built for. |
| `MESH` | `off` | `on` adds `snowflake` and `spock` to `shared_preload_libraries` and writes the mesh settings: logical WAL, Spock DDL replication, `snowflake.node` and `coldfront.loopback_dsn`. |
| `COLDFRONT_WAREHOUSE` | `wh` | The Lakekeeper warehouse name written to `coldfront.warehouse`. |
| `COLDFRONT_LAKEKEEPER` | `http://lakekeeper:8181/catalog` | The catalog endpoint written to `coldfront.lakekeeper_endpoint`. |
| `COLDFRONT_SNOWFLAKE_NODE` | `1` | The `snowflake.node` value of a mesh member; every member needs a distinct one. |
| `COLDFRONT_DUCKDB_ROLE` | `coldfront_duckdb` | The role written to `duckdb.postgres_role` and created `NOLOGIN`; an empty value keeps pg_duckdb's superuser-only default. |
| `COLDFRONT_STANDBY_OF` | unset | The host of a primary. The container then fills an empty data directory with `pg_basebackup` from that host and starts as a streaming standby. |
| `COLDFRONT_DUCKDB_VERSION` | `v1.5.4` | The version directory under `$PGDATA/pg_duckdb/extensions/` that receives the patched DuckDB extensions. |
| `COLDFRONT_DUCKDB_PLATFORM` | from `uname -m` | The platform directory under that version, `linux_amd64` or `linux_arm64`. |

### Verifying the Build

After you start the stack, a self-contained smoke test confirms that the stack
works end to end: pg_duckdb, the patched duckdb-iceberg, Lakekeeper, and the
object store. The fastest path needs no cloud credentials, because it uses the
SeaweedFS S3 emulator that the stack includes under the `local-store` profile:

1. In the shell where you exported `PG_MAJOR` and the port variables, bring
   the stack up with the `local-store` profile:

    ```bash
    docker compose --profile local-store up -d --build
    ```

2. Wait until `docker compose ps` reports the Lakekeeper container as healthy:

    ```bash
    until docker compose ps lakekeeper | grep -q '(healthy)'; do sleep 2; done
    ```

3. Bootstrap Lakekeeper, create the `wh` warehouse against the SeaweedFS
   credentials in
   [`docker/seaweedfs-s3.json`](https://github.com/pgEdge/ColdFront/blob/main/docker/seaweedfs-s3.json),
   and seed the `public` namespace:

    ```bash
    curl -sf -X POST http://localhost:8181/management/v1/bootstrap \
      -H 'Content-Type: application/json' -d '{"accept-terms-of-use":true}'

    WID=$(curl -s -X POST http://localhost:8181/management/v1/warehouse \
      -H 'Content-Type: application/json' -d '{
        "warehouse-name":"wh",
        "storage-profile":{"type":"s3","bucket":"iceberg","region":"us-east-1",
          "endpoint":"http://seaweedfs:8333","path-style-access":true,
          "flavor":"s3-compat","sts-enabled":false,"remote-signing-enabled":false},
        "storage-credential":{"type":"s3","credential-type":"access-key",
          "aws-access-key-id":"admin","aws-secret-access-key":"adminsecret"}
      }' \
      | grep -oE '"warehouse-id":"[^"]+"' | cut -d'"' -f4)

    if [ -z "$WID" ]; then
      echo "No warehouse ID - check that the warehouse create succeeded."
    else
      curl -s -X POST "http://localhost:8181/catalog/v1/$WID/namespaces" \
        -H 'Content-Type: application/json' -d '{"namespace":["public"]}'
    fi
    ```

    If you run these commands again after the warehouse exists, the create
    request fails and `WID` is empty. Set `WID` to the `warehouse-id` of the
    `wh` warehouse in the output of `curl -s
    http://localhost:8181/management/v1/warehouse`, then rerun the namespace
    request.

4. Create the extensions, set the cold-store secret, create a decoupled table,
   insert a row, and read it back through Iceberg:

    ```bash
    psql -h localhost -U coldfront -d coldfront <<'SQL'
    CREATE EXTENSION IF NOT EXISTS pg_duckdb;
    CREATE EXTENSION IF NOT EXISTS coldfront;
    SELECT coldfront.set_storage_secret('admin', 'adminsecret', 'seaweedfs:8333');
    SELECT coldfront.create_iceberg_table('public', 'events',
      '[{"name":"id","type":"bigint"},{"name":"ts","type":"timestamptz"},{"name":"note","type":"text"}]'::jsonb,
      '{month(ts)}');
    INSERT INTO events VALUES (1, now(), 'hello');
    SELECT count(*) FROM events;
    SQL
    ```

    The final query returns a count of `1` when the stack works end to end:
    ColdFront wrote the row to the object store through Iceberg and read it
    back.

To set up ColdFront against your own object store, bring the stack up without
the `local-store` profile and complete the following steps:

1. Bootstrap Lakekeeper, which initializes the catalog so that it accepts
   requests, as
   [Bootstrapping Lakekeeper](configure_lakekeeper.md#bootstrapping-lakekeeper)
   describes.
2. Create a Lakekeeper warehouse that points at your bucket, and an Iceberg
   namespace in that warehouse, as the same section describes.
3. Create the `pg_duckdb` and `coldfront` extensions in each database that
   uses ColdFront, as
   [Configuring PostgreSQL for Lakekeeper](configure_lakekeeper.md#configuring-postgresql-for-lakekeeper)
   describes.
4. Store the object store credentials with
   `coldfront.set_storage_secret()`, as the same section describes.
5. Create a table and tier it to the object store, as
   [Using ColdFront in Tiered Mode](usage_tiered.md) describes.

## Understanding ColdFront's DuckDB Stack

ColdFront runs on a DuckDB 1.5 stack that consists of PostgreSQL, pg_duckdb
built on DuckDB 1.5.4, and a patched build of duckdb-iceberg. When you install
ColdFront from packages, the package manager installs these patched
dependencies for you; when you build ColdFront from source, you need to build
and install the patched dependencies yourself.

The duckdb-iceberg build includes the following ColdFront patches:

- the bakery-aware commit-refresh patch (the no-409 guarantee for
  concurrent cold-tier writers).
- two strict-reader interop patches, so apache/iceberg-go, the cold-tier
  compactor, can read the manifests duckdb-iceberg writes.
- a port of an upstream fix that computes the time partitions of a
  `timestamptz` column in UTC.
- a port of another that numbers a new table schema above the highest
  schema id.
- a patch that keeps a table's vended storage secret across binds, so a
  statement that reads the table twice never has a read go out unsigned.
- a port of an upstream fix that makes a failed manifest read fail the query
  instead of aborting the backend.

ColdFront also patches pg_duckdb and the DuckDB that pg_duckdb compiles, to
close two security vulnerabilities. [Patching pg_duckdb](#patching-pg_duckdb)
and [Patching DuckDB](#patching-duckdb) explain each patch and the
vulnerability it closes.

No released pg_duckdb tag includes DuckDB 1.5.x yet, so the stack is built
from a pinned upstream PR plus ColdFront's patches - all from sources you
can fetch.

### Patching duckdb-iceberg

ColdFront applies the following patches to duckdb-iceberg:

| Patch | What it does |
|---|---|
| `iceberg-bakery-aware-commit-refresh-v15` | Refreshes the table head at the commit POST (and re-creates the table's storage secret in the commit context, needed under catalog credential vending) so concurrent cold writers never get a Lakekeeper 409 (the no-409 guarantee). It also lets writers queued behind the first commit into a never-written table proceed instead of failing as "already outdated". |
| `iceberg-manifest-list-format-version-v15` | Adds the spec-optional `format-version` key to the manifest-list metadata so strict Apache readers parse the entries as v2. |
| `iceberg-data-file-format-v15` | Upper-cases the data-file format in the manifest to match the spec enum strict readers check case-sensitively. |
| `iceberg-timestamptz-utc-transforms-v15` | Computes the year/month/day/hour partition of a `timestamptz` column on the UTC instant rather than in the session's time zone (a port of upstream duckdb-iceberg d3c3348271). |
| `iceberg-schema-id-allocation-v15` | Numbers a new table schema one above the highest schema id in the metadata rather than above the current one, so a column change after a `DROP COLUMN` that returned the table to an earlier schema is accepted (a port of upstream duckdb-iceberg c1cfe2ef). |
| `iceberg-vended-secret-keep-v15` | Keeps a table's vended storage secret when the same transaction binds the table again, instead of replacing it, so a manifest read running on another thread never finds the secret missing between the drop and the write and goes unsigned to the default endpoint. |
| `iceberg-manifest-read-error-v15` | Makes a failed manifest read fail the query rather than abort the backend: the shared scan state's destructor no longer lets the task error escape (a port of upstream duckdb-iceberg 45f323eb). |

The following list explains what each patch contributes:

- The bakery patch (`iceberg-bakery-aware-commit-refresh-v15`) is required for
  the no-409 guarantee.
- The two interop patches (`iceberg-manifest-list-format-version-v15` and
  `iceberg-data-file-format-v15`) make the manifests that duckdb-iceberg writes
  readable by strict Apache Iceberg readers, such as the cold-tier compactor,
  which uses apache/iceberg-go. They have no effect on pg_duckdb's own reads.
- The time zone patch (`iceberg-timestamptz-utc-transforms-v15`) keeps a
  partitioned cold table correct when a session whose time zone is not UTC
  writes to it.
- The schema ID patch (`iceberg-schema-id-allocation-v15`) lets a table take a
  new column after a change that returned it to an earlier schema.
- The vended secret patch (`iceberg-vended-secret-keep-v15`) keeps a table's
  vended storage secret across the binds of one transaction, so a read on
  another thread never goes out unsigned.
- The manifest read patch (`iceberg-manifest-read-error-v15`) makes a failed
  manifest read fail the query instead of aborting the backend.

[`docker/Dockerfile.duckdb15-base`](https://github.com/pgEdge/ColdFront/blob/main/docker/Dockerfile.duckdb15-base)
is the definitive source for every pinned source and compile step.

### Patching pg_duckdb

ColdFront applies one patch to pg_duckdb, `pg_duckdb-extract-field-quoting`,
which closes a security vulnerability.

pg_duckdb converts each query it runs on DuckDB into SQL text, using its own
copies of PostgreSQL's `ruleutils.c`. Those copies write the field name in
`EXTRACT(field FROM x)` exactly as given, without quotes. PostgreSQL's parser
accepts any string as the field name, so a crafted field name could reach
DuckDB as SQL and run there with the session's attachments and secrets.

The patch quotes the field name, as PostgreSQL's own `ruleutils.c` has done
since its fix for CVE-2026-15741. A valid field name, such as `year`, is
unchanged. Any other string is quoted, so DuckDB rejects it as a field name and
pg_duckdb hands the query back to PostgreSQL, which then rejects the unit. The
pg_duckdb packages built from `packaging/pg_duckdb` include the same patch.

### Patching DuckDB

ColdFront applies one patch to DuckDB, `duckdb-brotli-block-switch-v15`, which
closes a security vulnerability that no DuckDB release up to and including
2.0.0 fixes.

DuckDB 1.5.4 includes brotli 1.1.0, whose decoder has an out-of-bounds write
bug (CVE-2026-111497). DuckDB's Parquet reader uses that decoder for every
Brotli-compressed page, so reading a crafted Parquet file through DuckDB can
trigger the out-of-bounds write inside a PostgreSQL backend.

The patch ports the fix from brotli 1.1.1 into the copy of DuckDB 1.5.4 that
pg_duckdb compiles, so the decoder rejects the crafted data. The pg_duckdb RPM
and Debian packages include the same patch.

## Next Steps

To go further with ColdFront, consult the following guides:

- The [Configuring ColdFront](configuration.md) guide details PostgreSQL
  and ColdFront's own configuration.
- The [Configuring Lakekeeper](configure_lakekeeper.md) guide installs,
  configures, and bootstraps Lakekeeper, then installs the extensions that
  each database needs.
- The [Using ColdFront](using_coldfront/index.md) guide documents the tiered,
  decoupled, and standalone partitioned modes.
- The [Configuring your Object Store](object_store.md) guide connects the
  cold tier to an S3-compatible store, AWS S3, Google Cloud Storage, or Azure
  ADLS Gen2.
- The [Testing and Continuous Integration](testing_ci.md) guide describes how
  to run ColdFront's test suite and how CI tests each change.
