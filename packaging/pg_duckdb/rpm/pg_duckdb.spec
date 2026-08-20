%global sname pg_duckdb
# Package name uses a hyphen (pg-duckdb) to match the DEB naming
# (pgedge-postgresql-N-pg-duckdb); sname keeps the upstream underscore for the
# installed artifacts (pg_duckdb.so, pg_duckdb.control, tarball dir).
%global pkgname pg-duckdb

# --- Shared DuckDB engine ------------------------------------------------------
# libduckdb.so is PG-major independent (identical .text/.rodata in every
# per-major build), so it ships ONCE from the owner major's build as
# pgedge-libduckdb, into a pgEdge-private directory rather than the system
# libdir — the soname is unversioned, so a public install would squat a name any
# future distro duckdb package would want. pg_duckdb.so reaches it through an
# RPATH added in %%build. See packaging/pg_duckdb/common.sh for the full
# rationale — in short, shipping the identical library from all three packages
# gave them all the same build-id and therefore colliding /usr/lib/.build-id/
# entries, which made them refuse to install side by side.
#
# build-rpm.sh passes with_libduckdb=1 for exactly one major (the latest, from
# LIBDUCKDB_OWNER_PG_MAJOR in common.sh) and 0 for the rest — the comparison
# lives there rather than here so the owner is decided in one place for both
# RPM and DEB. Defaulting to 1 keeps a bare `rpmbuild` of a single major
# self-contained and installable.
%{!?with_libduckdb: %global with_libduckdb 1}
# libduckdb_dir is passed by build-rpm.sh from LIBDUCKDB_DIR in common.sh, so
# RPM and DEB install the engine to the same path and share one RPATH value; the
# fallback matches that default. Not %{_libdir}: this sits alongside the duckdb
# extensions under the same /usr/lib/pgedge/coldfront root (COLDFRONT_EXTDIR),
# and the literal path is identical on RPM and DEB.
%{!?libduckdb_dir: %global libduckdb_dir /usr/lib/pgedge/coldfront/libduckdb}

Name:		pgedge-%{pkgname}_%{pgmajorversion}
Version:	%{pg_duckdb_version}
Release:	%{pg_duckdb_buildnum}%{?dist}
Summary:	DuckDB analytics engine embedded in PostgreSQL
License:	MIT
URL:		https://github.com/duckdb/pg_duckdb
# Vendored tarball produced by build-rpm.sh that bundles the third_party/duckdb
# submodule (pinned by the pg_duckdb commit; GitHub auto-tarballs omit submodules).
Source0:	%{sname}-%{version}.tar.gz
# curl source, built and used at BUILD TIME ONLY on el9 (system libcurl 7.76 is
# too old to compile the DuckDB 1.5.x httpfs, which needs the curl >= 7.77 macro
# CURLSSLOPT_AUTO_CLIENT_CERT). Not shipped: the built .so references only the
# libcurl.so.4 soname + standard symbols that el9's 7.76 already provides, so at
# runtime the native system libcurl resolves it. el10 builds against system curl.
Source1:	curl-%{curl_version}.tar.gz

BuildRequires:	pgedge-postgresql%{pgmajorversion}-devel
BuildRequires:	cmake
BuildRequires:	ninja-build
BuildRequires:	gcc-c++
BuildRequires:	make
BuildRequires:	redhat-rpm-config
BuildRequires:	openssl-devel
BuildRequires:	lz4-devel
BuildRequires:	zlib-devel
BuildRequires:	libicu-devel
BuildRequires:	pkgconf-pkg-config
BuildRequires:	python3
BuildRequires:	git
# EL10+ compiles against the system libcurl (>= 7.77). On EL9 we build curl from
# Source1 instead, so libcurl-devel is intentionally NOT pulled there.
%if 0%{?rhel} >= 10
BuildRequires:	libcurl-devel
%endif
Requires:	pgedge-postgresql%{pgmajorversion}-server
# The DuckDB engine this pg_duckdb.so was linked against. Pinned by VERSION and
# not by NVR on purpose: DuckDB's C++ ABI is tied to the engine version, so
# 1.5.4 must never be paired with 1.5.5, but a rebuild of one major at a higher
# buildnum must still resolve against the engine already in the repo. Omitting
# the release is what buys that — rpm ignores the release when the requirement
# does not name one.
Requires:	pgedge-libduckdb = %{version}
# Native system libcurl at runtime on every EL (the curl >= 7.77 need is
# compile-time only; the curl HTTP path is unused — ColdFront forces httplib).
Requires:	libcurl
Requires:	lz4-libs
Provides:	%{pkgname}_%{pgmajorversion}

%description
pg_duckdb embeds DuckDB's columnar-vectorized analytics engine into PostgreSQL,
enabling high-performance analytical queries and direct access to data lakes and
external file formats (Parquet, CSV, Iceberg, object storage) from within
PostgreSQL.

%if %{with_libduckdb}
%package -n pgedge-libduckdb
Summary:	DuckDB engine shared library for pgEdge pg_duckdb
# Intentionally NO PostgreSQL dependency — this is plain DuckDB, shared by every
# pgedge-pg-duckdb_NN. Built only by the owner major's cell (see common.sh).
Requires:	libcurl

%description -n pgedge-libduckdb
The DuckDB columnar-vectorized analytics engine, built from the third_party/duckdb
submodule pinned by pgEdge's pg_duckdb and shared by the pg_duckdb extension for
every PostgreSQL major version.

This library contains no PostgreSQL-specific code; the per-major
pgedge-pg-duckdb_NN packages link against it and find it at runtime through an
RPATH, so they ship nothing but the extension itself.
%endif

%prep
%setup -q -n %{sname}-%{version}

%build
# pgEdge propagates -fexcess-precision=standard into CXXFLAGS, which gcc rejects
# for C++. Strip it after PGXS is included (no-op if absent).
printf '\noverride CXXFLAGS := $(filter-out -fexcess-precision=standard,$(CXXFLAGS))\n' >> Makefile.global

# Teach pg_duckdb.so where the shared engine lives. Upstream links it with
# -Wl,-rpath,$(PG_LIB) and a plain -lduckdb, which only worked while libduckdb.so
# sat in the PG libdir; it now lives in %{libduckdb_dir}, so add that to the
# RPATH. Appending to Makefile.global is what puts this AFTER `include $(PGXS)`
# (the same reason the CXXFLAGS override above goes here) — PGXS expands
# SHLIB_LINK when it runs the link, so a late append still lands.
# build-rpm.sh sets QA_RPATHS to allow the non-standard directory.
printf '\nSHLIB_LINK += -Wl,-rpath,%{libduckdb_dir}\n' >> Makefile.global

%if 0%{?rhel} && 0%{?rhel} < 10
# --- EL9 only: build curl >= 7.77 from source for the build (NOT shipped) ------
# Installed to a build-local prefix and exposed to find_package(CURL); we do NOT
# add it to any RUNPATH, so the produced .so resolves libcurl.so.4 from the
# system at runtime.
%global curl_prefix %{_builddir}/curl-install
mkdir -p %{curl_prefix}
tar xf %{SOURCE1} -C %{_builddir}
( cd %{_builddir}/curl-%{curl_version} \
  && ./configure --with-openssl --prefix=%{curl_prefix} --disable-static \
        --without-libpsl --without-libssh2 --without-nghttp2 --without-brotli --without-zstd \
  && %{__make} -j"$(nproc)" && %{__make} install )
export CMAKE_PREFIX_PATH=%{curl_prefix}${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}
export PKG_CONFIG_PATH=%{curl_prefix}/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}
export LIBRARY_PATH=%{curl_prefix}/lib${LIBRARY_PATH:+:$LIBRARY_PATH}
export CPATH=%{curl_prefix}/include${CPATH:+:$CPATH}
%endif

# DuckDB is a large C++17 build driven by CMake+Ninja under the PGXS Makefile.
# with_llvm=no matches the proven ColdFront recipe (no JIT bitcode shipped).
# Parallelism is capped to limit peak memory (DuckDB can OOM at high -j).
export DUCKDB_GEN=ninja
export CMAKE_BUILD_PARALLEL_LEVEL=4
USE_PGXS=1 PATH=%{pginstdir}/bin:$PATH %{__make} -j4 with_llvm=no

syft dir:%{_builddir}/%{sname}-%{version} -o cyclonedx-json > %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json || exit 1

KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec/{print $5}' | head -n 1); export KEY_ID
gpg --armor --detach-sign --local-user "$KEY_ID" --output %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json.asc %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json || exit 1

%install
%{__rm} -rf %{buildroot}
USE_PGXS=1 PATH=%{pginstdir}/bin:$PATH %{__make} install DESTDIR=%{buildroot} with_llvm=no
mkdir -p %{buildroot}/%{pginstdir}/sbom
install -p -m 0644 %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json %{buildroot}/%{pginstdir}/sbom/%{sname}-sbom.json
install -p -m 0644 %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json.asc %{buildroot}/%{pginstdir}/sbom/%{sname}-sbom.json.asc

# `make install` drops libduckdb.so next to pg_duckdb.so in the PG libdir. Only
# the owner major keeps it, relocated to the shared directory that %build put on
# pg_duckdb.so's RPATH; every other major deletes its identical copy BEFORE
# find-debuginfo runs, so no build-id entry is generated for it and nothing can
# collide. Nothing is left behind in the PG libdir — the loader finds the engine
# by RPATH, so there is no per-major link to keep in step.
%if %{with_libduckdb}
mkdir -p %{buildroot}%{libduckdb_dir}
mv %{buildroot}/%{pginstdir}/lib/libduckdb.so %{buildroot}%{libduckdb_dir}/libduckdb.so
%else
%{__rm} -f %{buildroot}/%{pginstdir}/lib/libduckdb.so
%endif

%files
%doc README.md
%license LICENSE
# The extension only. The DuckDB engine it links against ships separately, in
# pgedge-libduckdb (see the %%install note above).
%{pginstdir}/lib/%{sname}.so
%{pginstdir}/share/extension/%{sname}.control
%{pginstdir}/share/extension/%{sname}*.sql
%{pginstdir}/sbom/%{sname}-sbom.json
%{pginstdir}/sbom/%{sname}-sbom.json.asc

%if %{with_libduckdb}
%files -n pgedge-libduckdb
%license LICENSE
%dir %{libduckdb_dir}
%{libduckdb_dir}/libduckdb.so
%endif

%changelog
* Tue Jun 30 2026 Muhammad Aqeel <muhammad.aqeel@pgedge.com> - 1.5.4-1
- ColdFront build of pgEdge pg_duckdb (DuckDB 1.5.4, pg_duckdb PR #1025)
