#!/usr/bin/env bash
# Build dependencies, lint, package and (optionally) push one chart to oci://ghcr.io/<owner>/charts.
#
#   scripts/package.sh <chart-dir> <version> <registry> <dist-dir> <push true|false>
#
# <registry> is for example oci://ghcr.io/huponx/charts. A version that already exists in the registry is
# skipped (never overwritten); only "not found" means "publish", any other error (401, 403, network) fails.
# The chart must already carry <version> in Chart.yaml (update-chart-metadata).
# Prints "pushed=true|false" and "ref=<registry>/<name>:<version>". Needs helm (and yq).
set -euo pipefail

chart="${1:?usage: $0 <chart-dir> <version> <registry> <dist-dir> <push>}"
version="${2:?usage: $0 <chart-dir> <version> <registry> <dist-dir> <push>}"
registry="${3:?usage: $0 <chart-dir> <version> <registry> <dist-dir> <push>}"
dist="${4:?usage: $0 <chart-dir> <version> <registry> <dist-dir> <push>}"
push="${5:-false}"

name=$(yq '.name' "${chart}/Chart.yaml")
actual=$(yq '.version' "${chart}/Chart.yaml")
[ "${actual}" = "${version}" ] || { echo "::error::Chart.yaml version ${actual} is not ${version}" >&2; exit 1; }

mkdir -p "${dist}"
helm dependency build "${chart}" >&2

values=()
for f in "${chart}"/ci/*.yaml; do [ -e "${f}" ] && values+=(-f "${f}"); done
helm lint "${chart}" "${values[@]+"${values[@]}"}" >&2
helm template "${name}" "${chart}" "${values[@]+"${values[@]}"}" > /dev/null

if [ -d "${chart}/tests" ] && helm plugin list 2>/dev/null | grep -q unittest; then
  helm unittest "${chart}" >&2
fi

helm package "${chart}" --destination "${dist}" >&2
ref="${registry}/${name}:${version}"
echo "ref=${ref}"

if [ "${push}" != "true" ]; then
  echo "pushed=false"
  exit 0
fi

if probe=$(helm pull "${registry}/${name}" --version "${version}" --destination "$(mktemp -d)" 2>&1); then
  echo "::notice::${ref} already exists, not overwritten" >&2
  echo "pushed=false"
  exit 0
fi
if ! grep -qiE 'not found|manifest unknown|name unknown' <<<"${probe}"; then
  echo "::error::cannot check ${ref}: ${probe}" >&2
  exit 1
fi
helm push "${dist}/${name}-${version}.tgz" "${registry}" >&2
echo "pushed=true"
