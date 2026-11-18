#!/usr/bin/env bash
# Set version and appVersion in a Chart.yaml (the committed 0.0.0 is replaced at release time).
#
#   scripts/update.sh <chart-dir> <version> [app-version]
set -euo pipefail

chart="${1:?usage: $0 <chart-dir> <version> [app-version]}"
version="${2:?usage: $0 <chart-dir> <version> [app-version]}"
app_version="${3:-${version}}"
file="${chart%/}/Chart.yaml"
[ -f "${file}" ] || { echo "::error::${file} not found" >&2; exit 1; }

VERSION="${version}" APP_VERSION="${app_version}" yq -i '.version = strenv(VERSION) | .appVersion = strenv(APP_VERSION)' "${file}"
echo "${file}: version=${version} appVersion=${app_version}"
