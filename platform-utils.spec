# This spec file generates an RPM that installs platform utility
# scripts into the /opt/cray/platform-utils directory.
# Copyright 2020-2025 Hewlett Packard Enterprise Development LP

%define utils_dir /opt/cray/platform-utils

Name: platform-utils
Vendor: Hewlett Packard Enterprise Company
License: HPE Proprietary
Summary: Platform utils deployment
Version: %(cat .version)
Release: %(echo ${BUILD_METADATA})
Source: %{name}-%{version}.tar.bz2

# Compiling not currently required:
BuildArchitectures: noarch

Requires: jq
Requires: python311-boto3

%description
This RPM when installed will place platform utility scripts in
the /opt/cray/platform-utils directory.

%files
%defattr(755, root, root)
%dir %{utils_dir}
%dir %{utils_dir}/s3
%dir %{utils_dir}/etcd
%{utils_dir}/ncnGetXnames.sh
%{utils_dir}/ncnHealthChecks.sh
%{utils_dir}/ncnPostgresHealthChecks.sh
%{utils_dir}/detect_cpu_throttling.sh
%{utils_dir}/grafterm.sh
%{utils_dir}/move_pod.sh
%{utils_dir}/versions.sh
%{utils_dir}/s3/download-file.py
%{utils_dir}/s3/list-objects.py
%{utils_dir}/spire/fix-spire-on-storage.sh
%{utils_dir}/spire/spire-enable-tpm.sh
%{utils_dir}/spire/spire-disable-tpm.sh
%{utils_dir}/etcd/etcd_restore_rebuild.sh
%{utils_dir}/etcd/etcd-util.sh

%prep
%setup -q

%build

%install
install -m 755 -d %{buildroot}%{utils_dir}/
install -m 755 -d %{buildroot}%{utils_dir}/s3
install -m 755 -d %{buildroot}%{utils_dir}/spire
install -m 755 -d %{buildroot}%{utils_dir}/etcd
install -m 755 ncnGetXnames.sh %{buildroot}%{utils_dir}
install -m 755 ncnHealthChecks.sh %{buildroot}%{utils_dir}
install -m 755 ncnPostgresHealthChecks.sh %{buildroot}%{utils_dir}
install -m 755 detect_cpu_throttling.sh %{buildroot}%{utils_dir}
install -m 755 move_pod.sh %{buildroot}%{utils_dir}
install -m 755 versions.sh %{buildroot}%{utils_dir}
install -m 755 grafterm.sh %{buildroot}%{utils_dir}
install -m 755 s3/list-objects.py %{buildroot}%{utils_dir}/s3
install -m 755 s3/download-file.py %{buildroot}%{utils_dir}/s3
install -m 755 spire/fix-spire-on-storage.sh %{buildroot}%{utils_dir}/spire
install -m 755 spire/spire-enable-tpm.sh %{buildroot}%{utils_dir}/spire
install -m 755 spire/spire-disable-tpm.sh %{buildroot}%{utils_dir}/spire
install -m 755 etcd/etcd_restore_rebuild.sh %{buildroot}%{utils_dir}/etcd
install -m 755 etcd/etcd-util.sh %{buildroot}%{utils_dir}/etcd
