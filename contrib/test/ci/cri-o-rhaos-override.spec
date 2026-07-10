# RHAOS-compatible cri-o override RPM for OpenShift rpm-ostree replace.
#
# Customer path: rpm-ostree override replace + reboot (NOT --apply-live).
# Ships the same non-config files as stock cri-o (systemd, wipe, oci-umount,
# man pages, completions) plus dedup-enabled crio/pinns binaries.
# Does NOT replace OCP-managed config: crio.conf, cni, crictl.yaml.
#
# Build: hack/build-rhaos-override-rpm.sh

%global debug_package %{nil}

%global provider github
%global provider_tld com
%global project cri-o
%global repo cri-o
%global provider_prefix %{provider}.%{provider_tld}/%{project}/%{repo}
%global import_path %{provider_prefix}
%global git0 https://%{import_path}
%global service_name crio

Name: %{repo}
Version: 1.33.12
Release: 2.dedup%{?dist}
Summary: Kubernetes Container Runtime Interface for OCI-based containers (dedup)
License: ASL 2.0
URL: %{git0}
Source0: %{name}-test.tar.gz

BuildRequires: make
BuildRequires: git
BuildRequires: glib2-devel
BuildRequires: glibc-static
BuildRequires: go-md2man
BuildRequires: gpgme-devel
BuildRequires: libassuan-devel
BuildRequires: libseccomp-devel
BuildRequires: libselinux-devel
BuildRequires: pkgconfig(systemd)

Requires(pre): container-selinux
Requires: containers-common >= 1:0.1.24-3
Requires: runc > 1.0.0-57
Requires: containernetworking-plugins >= 0.7.5-1
Requires: conmon
Obsoletes: ocid <= 0.3
Provides: ocid = %{version}-%{release}
Provides: %{service_name} = %{version}-%{release}

%description
CRI-O override for OpenShift rpm-ostree with storage deduplication support
(crio dedup CLI and enable_storage_dedup). Matches stock package layout except
OCP node config files (crio.conf, CNI, crictl.yaml) which stay under MachineConfig.

%prep
%setup -qn %{name}-test
sed -i 's/install.config: crio.conf/install.config:/' Makefile
sed -i 's/install.bin: binaries/install.bin:/' Makefile
sed -i 's/\.gopathok//' Makefile
sed -i 's/go test/$(GO) test/' Makefile
sed -i 's/%{version}/%{version}-%{release}/' internal/version/version.go
sed -i 's/\/local//' contrib/systemd/%{service_name}.service
sed -i 's/\/local//' contrib/systemd/%{service_name}-wipe.service

%build
mkdir _output
pushd _output
mkdir -p src/%{provider}.%{provider_tld}/{%{project},opencontainers}
ln -s $(dirs +1 -l) src/%{import_path}
popd

ln -s vendor src
export GOPATH=$(pwd)/_output:$(pwd)
export BUILDTAGS="selinux seccomp exclude_graphdriver_btrfs containers_image_ostree_stub containers_image_openpgp"
make bin/crio bin/pinns
make GO_MD2MAN=go-md2man docs

%install
make PREFIX=%{buildroot}%{_usr} DESTDIR=%{buildroot} \
     install.bin \
     install.completions \
     install.man \
     install.systemd

install -dp %{buildroot}%{_sharedstatedir}/containers
install -dp %{buildroot}%{_datadir}/oci-umount/oci-umount.d
install -p -m 644 crio-umount.conf %{buildroot}%{_datadir}/oci-umount/oci-umount.d/%{service_name}-umount.conf
install -dp %{buildroot}%{_sysconfdir}/%{service_name}

%post
ln -sf %{_unitdir}/%{service_name}.service %{_unitdir}/%{repo}.service
%systemd_post %{service_name}

%preun
rm -f %{_unitdir}/%{repo}.service
%systemd_preun %{service_name}

%postun
%systemd_postun_with_restart %{service_name}

%files
%license LICENSE
%doc README.md
%{_bindir}/%{service_name}
%{_bindir}/pinns
%{_mandir}/man5/%{service_name}.conf.5*
%{_mandir}/man5/%{service_name}.conf.d.5*
%{_mandir}/man8/%{service_name}*.8*
%dir %{_sysconfdir}/%{service_name}
%{_unitdir}/%{service_name}.service
%{_unitdir}/%{service_name}-wipe.service
%dir %{_sharedstatedir}/containers
%dir %{_datadir}/oci-umount
%dir %{_datadir}/oci-umount/oci-umount.d
%{_datadir}/oci-umount/oci-umount.d/%{service_name}-umount.conf
%{_datadir}/bash-completion/completions/%{service_name}
%{_datadir}/fish/completions/%{service_name}.fish
%{_datadir}/zsh/site-functions/_%{service_name}

%changelog
* Tue Jun 30 2026 OCPNODE-4588 <ocpnode-4588@redhat.com> - 2.dedup-1
- Full non-config package layout for rpm-ostree reboot persistence
