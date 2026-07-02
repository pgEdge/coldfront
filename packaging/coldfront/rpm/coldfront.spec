%global sname coldfront

Name:		pgedge-%{sname}_%{pgmajorversion}
Version:	%{coldfront_version}
Release:	%{coldfront_buildnum}%{?dist}
Summary:	Transparent tiered storage for PostgreSQL (hot PG + cold Iceberg)
License:	PostgreSQL
URL:		https://github.com/pgEdge/ColdFront
# Local source: the coldfront extension tree (extension/coldfront) packed by
# build-rpm.sh, with LICENSE.md + README.md added at the top level.
Source0:	%{sname}-%{version}.tar.gz

BuildRequires:	pgedge-postgresql%{pgmajorversion}-devel
BuildRequires:	gcc
BuildRequires:	make
BuildRequires:	redhat-rpm-config
BuildRequires:	diffutils
Requires:	pgedge-postgresql%{pgmajorversion}-server
# coldfront drives DuckDB through pg_duckdb (shared_preload_libraries +
# duckdb.raw_query); it is non-functional without it.
Requires:	pgedge-pg-duckdb_%{pgmajorversion}
Provides:	%{sname}_%{pgmajorversion}

%description
ColdFront provides transparent tiered storage for PostgreSQL: DML on tiered
views is routed across a hot tier (PostgreSQL) and a cold tier (Apache Iceberg
over object storage), with cold reads/writes served through pg_duckdb. This
package contains the coldfront PostgreSQL extension (server module + SQL).

%prep
%setup -q -n %{sname}-%{version}

%build
# Pure PGXS C build (links libpq for the XactCallback loopback). with_llvm=no
# matches the proven ColdFront recipe (no JIT bitcode shipped).
USE_PGXS=1 PATH=%{pginstdir}/bin:$PATH %{__make} with_llvm=no

syft dir:%{_builddir}/%{sname}-%{version} -o cyclonedx-json > %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json || exit 1

KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec/{print $5}' | head -n 1); export KEY_ID
gpg --armor --detach-sign --local-user "$KEY_ID" --output %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json.asc %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json || exit 1

%install
%{__rm} -rf %{buildroot}
USE_PGXS=1 PATH=%{pginstdir}/bin:$PATH %{__make} install DESTDIR=%{buildroot} with_llvm=no
mkdir -p %{buildroot}/%{pginstdir}/sbom
install -p -m 0644 %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json %{buildroot}/%{pginstdir}/sbom/%{sname}-sbom.json
install -p -m 0644 %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json.asc %{buildroot}/%{pginstdir}/sbom/%{sname}-sbom.json.asc

%files
%doc README.md
%license LICENSE.md
%{pginstdir}/lib/%{sname}.so
%{pginstdir}/share/extension/%{sname}.control
%{pginstdir}/share/extension/%{sname}*.sql
%{pginstdir}/sbom/%{sname}-sbom.json
%{pginstdir}/sbom/%{sname}-sbom.json.asc

%changelog
* Mon Jun 30 2026 Muhammad Aqeel <muhammad.aqeel@pgedge.com> - 1.0.0-1
- Initial build of the pgEdge ColdFront extension
