#!/bin/bash
set -euo pipefail

RHEL="$(rpm --eval %rhel)"

prepare() {
  setup_dnf_build_env

  echo "Copying packaging files..."
  cp "${COMPONENT_NAME}/rpm/coldfront.spec" ~/rpmbuild/SPECS/

  echo "Packing the coldfront extension source..."
  rm -rf "/tmp/coldfront-${COLDFRONT_VERSION}"
  cp -rp extension/coldfront "/tmp/coldfront-${COLDFRONT_VERSION}"
  # License + README travel with the package (PostgreSQL-licensed).
  cp LICENSE.md README.md "/tmp/coldfront-${COLDFRONT_VERSION}/"
  tar czf ~/rpmbuild/SOURCES/coldfront-${COLDFRONT_VERSION}.tar.gz \
    -C /tmp "coldfront-${COLDFRONT_VERSION}"

  # This function is for debugging purpose if you have your own keys. GH workflow does not need it.
  #import_gpg_keys

  echo "🔧 Installing RPM build dependencies..."
  dnf builddep -y \
    --define "pgmajorversion ${PG_MAJOR_VERSION}" \
    --define "pginstdir /usr/pgsql-${PG_MAJOR_VERSION}" \
    --define "coldfront_version ${COLDFRONT_VERSION}" \
    --define "coldfront_buildnum ${COLDFRONT_BUILDNUM}" \
    ~/rpmbuild/SPECS/coldfront.spec
}

build() {
  echo "Building RPM and SRPM..."
  QA_RPATHS=$(( 0xffff )) rpmbuild -ba ~/rpmbuild/SPECS/coldfront.spec \
    --define "pgmajorversion ${PG_MAJOR_VERSION}" \
    --define "pginstdir /usr/pgsql-${PG_MAJOR_VERSION}" \
    --define "coldfront_version ${COLDFRONT_VERSION}" \
    --define "coldfront_buildnum ${COLDFRONT_BUILDNUM}"
}

post_build() {
  echo "📤 Copying built RPMs to /output..."
  mkdir -p /output
  cp -v ~/rpmbuild/RPMS/*/*.rpm /output/ || echo "No binary RPMs found"
  cp -v ~/rpmbuild/SRPMS/*.src.rpm /output/ || echo "No SRPM found"

  sign_rpms /output/*.rpm
  validate_signatures /output/*.rpm
}
