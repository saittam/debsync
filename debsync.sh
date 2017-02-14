#!/bin/bash
#
# Syncs debian packages from a github release to a local debian repo.
#

# Bail on errors.
set -e
set -o pipefail

# Base directory of the script and associated resources.
debsync_base=$(readlink -f "$(dirname "$0")")

# Local package repository directory. Packages are copied here.
package_repo='/usr/local/pkg/rkt'

# Runs a command in a sandboxed environment.
sandbox() {
  local firejail_profile="${debsync_base}/firejail/$(basename $1).profile"
  local firejail_cmd=
  printf -v firejail_cmd '%q ' \
      /usr/bin/firejail --quiet --profile="${firejail_profile}" -- "$@"
  su -s /bin/bash -l -c "${firejail_cmd}" nobody
}

wget_safe() {
  sandbox wget --quiet --output-document=- "$@" | head -c 512M
}

jq_safe() {
  sandbox jq "$@" | head -c 10K
}

# Runs a command and only prints its diagnostic output on failure.
silence() {
  local spoolfile=$(mktemp -p "${tmpdir}")
  "$@" 2>"${spoolfile}" || (cat "$spoolfile" 1>&2 ; exit 1)
}

# Main script starts here.

# Set up a temporary directory.
tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT

# Download latest release information.  
release_json="${tmpdir}/release.json"
wget_safe 'https://api.github.com/repos/coreos/rkt/releases/latest' \
    > "${release_json}"

# Figure out the debian package file name.
raw_package_name=$(jq_safe -r '
    .assets |
    map(select((.name | startswith("rkt")) and
               (.name | endswith("amd64.deb")))) |
    .[0].name' < "${release_json}")
safe_package_name=$(echo "${raw_package_name}" | tr -d -c '[a-zA-Z0-9._\-]')

# Find the asset URLs corresponding to the debian package and its signature.
package_asset_url=$(jq_safe -r --arg name "${raw_package_name}" '
    .assets | map(select(.name == $name)) | .[0].url
    ' < "${release_json}")
signature_asset_url=$(jq_safe -r --arg name "${raw_package_name}.asc" '
    .assets | map(select(.name == $name)) | .[0].url
    ' < "${release_json}")

# Download the assets.
package_file="${tmpdir}/${safe_package_name}"
wget_safe --header="Accept: application/octet-stream" "${package_asset_url}" \
    > "${package_file}"
signature_file="${tmpdir}/${safe_package_name}.asc"
wget_safe --header="Accept: application/octet-stream" "${signature_asset_url}" \
    > "${signature_file}"

# Check signature.
silence gpg --no-verbose --batch --quiet --no-tty \
    --no-default-keyring --keyring "${debsync_base}/coreos.gpg" --always-trust \
    --verify "${signature_file}" "${package_file}"

# Move downloaded file to local package repository.
mkdir -p "${package_repo}/amd64"
mv "${package_file}" "${package_repo}/amd64/${safe_package_name}"

# Update packages file.
(cd "${package_repo}" && silence dpkg-scanpackages -m . > "Packages")
