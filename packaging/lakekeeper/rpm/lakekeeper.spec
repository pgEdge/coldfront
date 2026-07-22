%global sname lakekeeper

# Prebuilt binary — no debug info / source to extract, so disable the (empty)
# debuginfo/debugsource subpackages. The binary is stripped in %%install.
%global debug_package %{nil}

Name:           pgedge-%{sname}
Version:        %{lakekeeper_version}
Release:        %{lakekeeper_buildnum}%{?dist}
Summary:        Lakekeeper - Apache Iceberg REST Catalog

License:        Apache-2.0
URL:            https://lakekeeper.io

# Upstream prebuilt release binary (glibc/gnu target), staged into SOURCES by
# build-rpm.sh. Arch-specific; nothing is compiled here.
Source0:        lakekeeper-%{lk_arch}-unknown-linux-gnu.tar.gz
Source1:        lakekeeper.service
Source2:        lakekeeper.env
Source3:        LICENSE
Source4:        NOTICE
Source5:        README.md

BuildArch:      %{_arch}

BuildRequires:  systemd-rpm-macros
Requires(pre):  shadow-utils
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd
Requires:       systemd

# Own the upstream name so this can't be co-installed with a community build.
Conflicts:      lakekeeper
Provides:       lakekeeper

%description
Lakekeeper is an implementation of the Apache Iceberg REST Catalog. It stores
catalog state in PostgreSQL and serves the Iceberg REST API to query engines
and data tools.

This package installs the prebuilt lakekeeper binary and a systemd service.
Lakekeeper requires an external PostgreSQL 15+ database and is NOT enabled or
started automatically: configure /etc/lakekeeper/lakekeeper.env and run the
one-time database migration first (see the bundled README).

%prep
# The release tarball contains only the `lakekeeper` binary (no wrapping
# directory); -c creates one and extracts into it.
%setup -q -c -n %{sname}-%{version}
cp -p %{SOURCE3} %{SOURCE4} %{SOURCE5} .

%build
syft dir:%{_builddir}/%{sname}-%{version} -o cyclonedx-json > %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json || exit 1

KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec/{print $5}' | head -n 1); export KEY_ID
gpg --armor --detach-sign --local-user "$KEY_ID" --output %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json.asc %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json || exit 1

%install
install -D -m 0755 lakekeeper %{buildroot}%{_bindir}/lakekeeper
# Prebuilt binary ships unstripped (~155 MB) — strip to shrink the package.
strip %{buildroot}%{_bindir}/lakekeeper || :
install -D -m 0644 %{SOURCE1} %{buildroot}%{_unitdir}/lakekeeper.service
install -D -m 0640 %{SOURCE2} %{buildroot}%{_sysconfdir}/lakekeeper/lakekeeper.env
install -D -m 0644 %{sname}-sbom.json     %{buildroot}%{_datadir}/pgedge-%{sname}/%{sname}-sbom.json
install -D -m 0644 %{sname}-sbom.json.asc %{buildroot}%{_datadir}/pgedge-%{sname}/%{sname}-sbom.json.asc

%pre
# Create the lakekeeper group and system user.
getent group lakekeeper >/dev/null || groupadd -r lakekeeper
getent passwd lakekeeper >/dev/null || \
    useradd -r -g lakekeeper -d /var/lib/lakekeeper -s /sbin/nologin \
    -c "Lakekeeper Iceberg REST Catalog" lakekeeper
exit 0

%post
%systemd_post lakekeeper.service

%preun
%systemd_preun lakekeeper.service

%postun
%systemd_postun_with_restart lakekeeper.service

%files
%license LICENSE
%doc NOTICE README.md
%{_bindir}/lakekeeper
%{_unitdir}/lakekeeper.service
%dir %{_sysconfdir}/lakekeeper
%attr(0640, root, lakekeeper) %config(noreplace) %{_sysconfdir}/lakekeeper/lakekeeper.env
%dir %{_datadir}/pgedge-%{sname}
%{_datadir}/pgedge-%{sname}/%{sname}-sbom.json
%{_datadir}/pgedge-%{sname}/%{sname}-sbom.json.asc

%changelog
* Mon Jul 06 2026 pgEdge Build Team <support@pgedge.com> - 0.13.1-1
- Initial package of Lakekeeper (Apache Iceberg REST Catalog) from the upstream prebuilt binary
