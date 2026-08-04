#!/bin/bash
set -euo pipefail

RHEL="$(rpm --eval %rhel)"
ARCH=$(uname -m)                       # x86_64 | aarch64 (rpm arch)
case "$ARCH" in
  x86_64)  GOARCH=amd64 ;;
  aarch64) GOARCH=arm64 ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

# Release assets are named with the full tag version (e.g. 1.0.0). The binaries
# come from the GoReleaser tarball built in the same release run.
TAG_VERSION="${COLDFRONT_BRANCH#v}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$(pwd)/release-artifacts}"
RELEASE_URL="https://github.com/pgEdge/ColdFront/releases/download/${COLDFRONT_BRANCH}"

# Prefer the workflow-staged tarball (release-artifacts/) so the package cell
# uses THIS run's binaries; else download from the GitHub release.
stage() {
  local local_name="$1" remote_name="$2" dest="$3"
  if [ -f "${ARTIFACT_DIR}/${local_name}" ]; then
    cp "${ARTIFACT_DIR}/${local_name}" "${dest}"
  else
    wget -q "${RELEASE_URL}/${remote_name}" -O "${dest}"
  fi
}

prepare() {
  setup_dnf_build_env

  echo "Copying packaging files..."
  cp "${COMPONENT_NAME}/rpm/coldfront.spec" ~/rpmbuild/SPECS/

  echo "Staging ColdFront binaries tarball (${GOARCH})..."
  stage "coldfront.tar.gz" "coldfront_${TAG_VERSION}_linux_${GOARCH}.tar.gz" \
        ~/rpmbuild/SOURCES/coldfront-${COLDFRONT_VERSION}-${ARCH}.tar.gz

  # This function is for debugging purpose if you have your own keys. GH workflow does not need it.
  #import_gpg_keys
}

build() {
  echo "Building RPM and SRPM..."
  QA_RPATHS=$(( 0xffff )) rpmbuild -ba ~/rpmbuild/SPECS/coldfront.spec \
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
