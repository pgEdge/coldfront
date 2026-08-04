#!/bin/bash
set -euo pipefail

# setup_dnf_build_env (common-functions.sh) reads $RHEL under `set -u`.
RHEL="$(rpm --eval %rhel)"

# uname arch matches the upstream target-triple prefix (x86_64 / aarch64).
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|aarch64) : ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

RELEASE_URL="https://github.com/lakekeeper/lakekeeper/releases/download/v${LAKEKEEPER_VERSION}"
REPO_RAW="https://raw.githubusercontent.com/lakekeeper/lakekeeper/v${LAKEKEEPER_VERSION}"

prepare() {
  setup_dnf_build_env

  echo "Copying packaging files..."
  cp "${COMPONENT_NAME}/rpm/lakekeeper.spec"       ~/rpmbuild/SPECS/
  cp "${COMPONENT_NAME}/common/lakekeeper.service" ~/rpmbuild/SOURCES/
  cp "${COMPONENT_NAME}/common/lakekeeper.env"     ~/rpmbuild/SOURCES/
  cp "${COMPONENT_NAME}/README.md"                 ~/rpmbuild/SOURCES/

  local tarball="lakekeeper-${ARCH}-unknown-linux-gnu.tar.gz"
  echo "Downloading lakekeeper ${LAKEKEEPER_VERSION} binary (${ARCH})..."
  wget -q "${RELEASE_URL}/${tarball}" -O ~/rpmbuild/SOURCES/"${tarball}"

  # LICENSE + NOTICE are not shipped inside the release tarball; fetch them from
  # the repo at the matching tag for %license/%doc.
  echo "Fetching LICENSE + NOTICE from the ${LAKEKEEPER_VERSION} tag..."
  wget -q "${REPO_RAW}/LICENSE" -O ~/rpmbuild/SOURCES/LICENSE
  wget -q "${REPO_RAW}/NOTICE"  -O ~/rpmbuild/SOURCES/NOTICE

  # This function is for debugging purpose if you have your own keys. GH workflow does not need it.
  #import_gpg_keys
}

build() {
  echo "Building RPM and SRPM..."
  QA_RPATHS=$(( 0xffff )) rpmbuild -ba ~/rpmbuild/SPECS/lakekeeper.spec \
    --define "lakekeeper_version ${LAKEKEEPER_VERSION}" \
    --define "lakekeeper_buildnum ${LAKEKEEPER_BUILDNUM}" \
    --define "lk_arch ${ARCH}"
}

post_build() {
  echo "📤 Copying built RPMs to /output..."
  mkdir -p /output
  cp -v ~/rpmbuild/RPMS/*/*.rpm /output/ || echo "No binary RPMs found"
  cp -v ~/rpmbuild/SRPMS/*.src.rpm /output/ || echo "No SRPM found"

  sign_rpms /output/*.rpm
  validate_signatures /output/*.rpm
}
