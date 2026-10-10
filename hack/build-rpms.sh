#!/usr/bin/env bash

# This script generates release zips and RPMs into _output/releases.
# tito and other build dependencies are required on the host. We will
# be running `hack/build-cross.sh` under the covers, so we transitively
# consume all of the relevant envars.
source "$(dirname "${BASH_SOURCE}")/lib/init.sh"

os::util::ensure::system_binary_exists rpmbuild
os::util::ensure::system_binary_exists createrepo

# Create version file if git describe fails (e.g., release branches without reachable tags)
if ! git describe --long --tags --abbrev=7 --match 'v[0-9]*' HEAD >/dev/null 2>&1; then
    os::log::info "No version tags found, extracting version from source..."
    # Extract version from internal/version/version.go
    CRIO_VERSION=$(grep 'const Version = ' "${OS_ROOT}/internal/version/version.go" | cut -d'"' -f2)
    GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    GIT_TREE_STATE="clean"
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        GIT_TREE_STATE="dirty"
    fi

    # Extract major.minor.patch
    VERSION_MAJOR=$(echo "${CRIO_VERSION}" | cut -d. -f1)
    VERSION_MINOR=$(echo "${CRIO_VERSION}" | cut -d. -f2)
    VERSION_PATCH=$(echo "${CRIO_VERSION}" | cut -d. -f3)

    # Create temporary version file
    VERSION_FILE="${BASETMPDIR}/version"
    mkdir -p "$(dirname "${VERSION_FILE}")"
    cat > "${VERSION_FILE}" <<EOF
OS_GIT_COMMIT='${GIT_COMMIT}'
OS_GIT_TREE_STATE='${GIT_TREE_STATE}'
OS_GIT_VERSION='v${CRIO_VERSION}+${GIT_COMMIT}-0'
OS_GIT_MAJOR='${VERSION_MAJOR}'
OS_GIT_MINOR='${VERSION_MINOR}'
OS_GIT_PATCH='${VERSION_PATCH}'
EOF
    export OS_VERSION_FILE="${VERSION_FILE}"
    os::log::info "Using version v${CRIO_VERSION} from source"
fi

os::build::rpm::get_nvra_vars

OS_RPM_SPECFILE="$(find "${OS_ROOT}" -name *cri-o.spec)"
OS_RPM_NAME="$(rpmspec -q --qf '%{name}\n' "${OS_RPM_SPECFILE}" | head -1)"

os::log::info "Building release RPMs for ${OS_RPM_SPECFILE} ..."

rpm_tmp_dir="${BASETMPDIR}/rpm"
ci_data="${OS_ROOT}/contrib/test/ci"
# RPM requires the spec file be owned by the invoking user
chown "$(id -u):$(id -g)" "${OS_RPM_SPECFILE}" || true

mkdir -p "${rpm_tmp_dir}/SOURCES"
tar czf "${rpm_tmp_dir}/SOURCES/${OS_RPM_NAME}-test.tar.gz" \
    --owner=0 --group=0 \
    --exclude=_output --exclude=.git --transform "s|^|${OS_RPM_NAME}-test/|rSH" \
    .
cp -r "${ci_data}/." "${rpm_tmp_dir}/SOURCES"

# Some CI environments do not have IPv6 connectivity, while vault.centos.org
# resolves to both IPv4 and IPv6 addresses. This result in occasional
# "Network is unreachable" errors. Workaround: disable IPv6 for yum.
if [ -w /etc/yum.conf ] && ! grep -q '^ip_resolve' /etc/yum.conf; then
    os::log::info "Disabling IPv6 for yum ..."
    echo 'ip_resolve=4' >>/etc/yum.conf
fi
# Just in case builddep isn't an installed plugin
dnf -y install 'dnf-command(builddep)'
dnf builddep -y "${OS_RPM_SPECFILE}" || true

# Ensure to use latest golang
GO_VERSION=$(curl -sSfL "https://go.dev/VERSION?m=text" | head -n1)
curl -sSfL -o- "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" | tar xfz - -C /usr/local
export PATH=/usr/local/go/bin:$PATH
export GOCACHE="${rpm_tmp_dir}/go-cache"

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

# migrate the rpm artifacts to the output directory, must be clean or move will fail
make clean
mkdir -p "${OS_OUTPUT}"

mkdir -p "${OS_OUTPUT_RPMPATH}"
mv -f "${rpm_tmp_dir}"/SRPMS/*src.rpm "${OS_OUTPUT_RPMPATH}"
mv -f "${rpm_tmp_dir}"/RPMS/*/*.rpm "${OS_OUTPUT_RPMPATH}"

mkdir -p "${OS_OUTPUT_RELEASEPATH}"
echo "${OS_GIT_COMMIT}" >"${OS_OUTPUT_RELEASEPATH}/.commit"

repo_path=${OS_OUTPUT_RPMPATH}
createrepo "${repo_path}"

echo "[${OS_RPM_NAME}-local-release]
baseurl = file://${repo_path}
gpgcheck = 0
name = Release from Local Source for ${OS_RPM_NAME}
enabled = 1
" >"${repo_path}/local-release.repo"

# DEPRECATED: preserve until jobs migrate to using local-release.repo
cp "${repo_path}/local-release.repo" "${repo_path}/cri-o-local-release.repo"

os::log::info "Repository file for \`yum\` or \`dnf\` placed at ${repo_path}/local-release.repo
Install it with:
$ mv '${repo_path}/local-release.repo' '/etc/yum.repos.d"
