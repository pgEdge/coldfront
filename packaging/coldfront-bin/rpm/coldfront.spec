%global sname coldfront

# Prebuilt, fully-stripped static Go binaries — there is no debug info or source
# to extract, so disable the (empty) debuginfo/debugsource subpackages.
%global debug_package %{nil}

Name:		pgedge-%{sname}
Version:	%{coldfront_version}
Release:	%{coldfront_buildnum}%{?dist}
Summary:	ColdFront tiered-storage command-line tools
License:	PostgreSQL
URL:		https://github.com/pgEdge/ColdFront
# Prebuilt static Go binaries from the GoReleaser tarball (built in the same
# release run), staged into SOURCES by build-rpm.sh. Arch-specific, no compile.
Source0:	%{sname}-%{version}-%{_arch}.tar.gz

# Pure static Go binaries (CGO_ENABLED=0) — no runtime library dependencies and
# nothing to compile here, so no BuildRequires beyond syft (installed by
# setup_dnf_build_env) for the SBOM.
BuildArch:	%{_arch}

%description
ColdFront provides transparent tiered storage for PostgreSQL (hot PG + cold
Iceberg over object storage). This package contains the ColdFront tools:
archiver (cold-tier writer), partitioner, and compactor (Iceberg maintenance).
These are PostgreSQL-version-independent, statically linked binaries.

%prep
# The GoReleaser archive has no wrapping directory; -c creates one and extracts.
%setup -q -c -n %{sname}-%{version}

%build
syft dir:%{_builddir}/%{sname}-%{version} -o cyclonedx-json > %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json || exit 1

KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec/{print $5}' | head -n 1); export KEY_ID
gpg --armor --detach-sign --local-user "$KEY_ID" --output %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json.asc %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json || exit 1

%install
%{__rm} -rf %{buildroot}
install -D -m 0755 archiver    %{buildroot}%{_bindir}/archiver
install -D -m 0755 partitioner %{buildroot}%{_bindir}/partitioner
install -D -m 0755 compactor   %{buildroot}%{_bindir}/compactor
# Ship the example deployment config as the default config file. The tools take
# `-config <path>`; point them at this. Installed %config(noreplace) so an admin's
# edited copy survives upgrades (a new default lands as config.yaml.rpmnew).
install -D -m 0644 config.example.yaml %{buildroot}%{_sysconfdir}/pgedge/coldfront/config.yaml
install -D -m 0644 %{sname}-sbom.json     %{buildroot}%{_datadir}/pgedge-%{sname}/%{sname}-sbom.json
install -D -m 0644 %{sname}-sbom.json.asc %{buildroot}%{_datadir}/pgedge-%{sname}/%{sname}-sbom.json.asc

%files
%license LICENSE.md
%doc README.md
%{_bindir}/archiver
%{_bindir}/partitioner
%{_bindir}/compactor
%dir %{_sysconfdir}/pgedge
%dir %{_sysconfdir}/pgedge/coldfront
%config(noreplace) %{_sysconfdir}/pgedge/coldfront/config.yaml
%{_datadir}/pgedge-%{sname}/%{sname}-sbom.json
%{_datadir}/pgedge-%{sname}/%{sname}-sbom.json.asc

%changelog
* Tue Jun 30 2026 Muhammad Aqeel <muhammad.aqeel@pgedge.com> - 1.0.0-1
- Initial build of the pgEdge ColdFront tools (archiver, partitioner, compactor)
