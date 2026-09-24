#!/usr/bin/env bash
# Build a binary-only cri-o RPM suitable for rpm-ostree override replace on OCP.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"

os::util::ensure::system_binary_exists rpmbuild

OS_RPM_SPECFILE="${OS_ROOT}/contrib/test/ci/cri-o-rhaos-override.spec"
OS_RPM_NAME="cri-o"

os::build::rpm::get_nvra_vars

os::log::info "Building RHAOS override RPM from ${OS_RPM_SPECFILE} ..."

rpm_tmp_dir="${BASETMPDIR}/rpm"
mkdir -p "${rpm_tmp_dir}/SOURCES"
tar czf "${rpm_tmp_dir}/SOURCES/${OS_RPM_NAME}-test.tar.gz" \
	--owner=0 --group=0 \
	--exclude=_output --exclude=.git \
	--transform "s|^|${OS_RPM_NAME}-test/|rSH" \
	.

chown "$(id -u):$(id -g)" "${OS_RPM_SPECFILE}" 2>/dev/null || true

# Pin Go to go.mod requirement; upstream Go lacks ecdsa.HashSign needed for
# libtrust_openssl (RHAOS uses a patched toolchain). CI tags use no_openssl.
GO_VERSION="go1.24.3"
curl -sSfL -o- "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" | tar xfz - -C /usr/local
export PATH=/usr/local/go/bin:$PATH
go version

rpmbuild -ba "${OS_RPM_SPECFILE}" \
	--define "_sourcedir ${rpm_tmp_dir}/SOURCES" \
	--define "_specdir ${rpm_tmp_dir}/SOURCES" \
	--define "_rpmdir ${rpm_tmp_dir}/RPMS" \
	--define "_srcrpmdir ${rpm_tmp_dir}/SRPMS" \
	--define "_builddir ${rpm_tmp_dir}/BUILD" \
	--define "version ${OS_RPM_VERSION}" \
	--define "release ${OS_RPM_RELEASE}" \
	--define "commit ${OS_GIT_COMMIT}" \
	--define 'debug_package %{nil}'

mkdir -p "${OS_OUTPUT_RPMPATH}"
mv -f "${rpm_tmp_dir}"/RPMS/*/*.rpm "${OS_OUTPUT_RPMPATH}/"

os::log::info "Built: ${OS_OUTPUT_RPMPATH}/$(ls "${OS_OUTPUT_RPMPATH}"/*.rpm | xargs -n1 basename)"
