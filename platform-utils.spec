# This spec file generates an RPM that installs platform utility
# scripts into the /opt/cray/platform-utils directory.
# Copyright 2020 Hewlett Packard Enterprise Development LP

%define utils_dir /opt/cray/platform-utils

Name: platform-utils
Vendor: Hewlett Packard Enterprise Company
License: HPE Proprietary 
Summary: Platform utils deployment
Version: 0.1.4
Release: %(echo ${BUILD_METADATA})
Source: %{name}-%{version}.tar.bz2

# Compiling not currently required:
BuildArchitectures: noarch

# In future the jq requirement can be added when needed by a tool. 
# Requires: jq

%description
This RPM when installed will place platform utility scripts in
the /opt/cray/platform-utils directory.

%files
%defattr(755, root, root)
%dir %{utils_dir}
%{utils_dir}/ncnHealthChecks.sh
%{utils_dir}/ncnPostgresHealthChecks.sh

%prep
%setup -q

%build

%install
install -m 755 -d %{buildroot}%{utils_dir}/
install -m 755 ncnHealthChecks.sh %{buildroot}%{utils_dir}
install -m 755 ncnPostgresHealthChecks.sh %{buildroot}%{utils_dir}


