%global sname coldfront-duckdb-extensions

# DuckDB .duckdb_extension files are shared objects with a DuckDB metadata footer
# appended; rpm's strip / debuginfo extraction would corrupt that footer and make
# DuckDB reject the extension. Disable all binary post-processing.
%global debug_package %{nil}
%global __strip /bin/true
%global __brp_strip %{nil}
%global __brp_strip_static_archive %{nil}
%global __brp_strip_comment_note %{nil}

Name:		pgedge-%{sname}
Version:	%{duckdb_ext_version}
Release:	%{duckdb_ext_buildnum}%{?dist}
Summary:	Patched DuckDB extensions for ColdFront tiered storage
License:	MIT
URL:		https://github.com/pgEdge/ColdFront
# Prebuilt .duckdb_extension binaries (built by build-rpm.sh from the patched
# duckdb-iceberg tree against DuckDB v%{duckdb_version}), staged into SOURCES.
Source0:	%{sname}-%{version}.tar.gz

%description
The patched DuckDB extensions ColdFront's cold tier needs — iceberg, avro,
azure, and postgres_scanner — built against DuckDB v%{duckdb_version} and
carrying ColdFront's bakery-aware-commit-refresh and interop patches. They are
loaded by pg_duckdb; point duckdb.extension_directory at %{extdir} (see the
installed config sample) so pg_duckdb loads these instead of downloading the
unpatched upstream builds.

%prep
# build-rpm.sh's tarball already has a %{sname}-%{version}/ wrapping dir, so a
# plain %setup (no -c) extracts + cd's into it (files at the build CWD).
%setup -q -n %{sname}-%{version}

%build
# No compilation here — the extensions are prebuilt. Generate + sign the SBOM.
syft dir:%{_builddir}/%{sname}-%{version} -o cyclonedx-json > %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json || exit 1

KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec/{print $5}' | head -n 1); export KEY_ID
gpg --armor --detach-sign --local-user "$KEY_ID" --output %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json.asc %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json || exit 1

%install
%{__rm} -rf %{buildroot}
# DuckDB locates extensions under <extdir>/v<engine>/<platform>/ — the version
# segment is the clean engine version (%{duckdb_version}), NOT the package
# Version (which may carry a pre-release pretag).
extdir_full="%{buildroot}%{extdir}/v%{duckdb_version}/%{duckdb_platform}"
mkdir -p "$extdir_full"
for e in iceberg avro azure postgres_scanner; do
    install -m 0644 "${e}.duckdb_extension" "$extdir_full/${e}.duckdb_extension"
done
install -D -m 0644 %{sname}.conf.sample %{buildroot}%{_datadir}/pgedge-%{sname}/%{sname}.conf.sample
install -D -m 0644 %{sname}-sbom.json     %{buildroot}%{_datadir}/pgedge-%{sname}/%{sname}-sbom.json
install -D -m 0644 %{sname}-sbom.json.asc %{buildroot}%{_datadir}/pgedge-%{sname}/%{sname}-sbom.json.asc

%files
%license LICENSE.md
%doc README.md
%dir %{extdir}
%{extdir}/v%{duckdb_version}/%{duckdb_platform}/iceberg.duckdb_extension
%{extdir}/v%{duckdb_version}/%{duckdb_platform}/avro.duckdb_extension
%{extdir}/v%{duckdb_version}/%{duckdb_platform}/azure.duckdb_extension
%{extdir}/v%{duckdb_version}/%{duckdb_platform}/postgres_scanner.duckdb_extension
%{_datadir}/pgedge-%{sname}/%{sname}.conf.sample
%{_datadir}/pgedge-%{sname}/%{sname}-sbom.json
%{_datadir}/pgedge-%{sname}/%{sname}-sbom.json.asc

%changelog
* Tue Jul 01 2026 Muhammad Aqeel <muhammad.aqeel@pgedge.com> - 1.5.4-1
- Initial build of the ColdFront patched DuckDB extensions (DuckDB 1.5.4)
