#!/usr/bin/env bash
# Write the image tag into the chart values at every given yq path (and optionally the repository).
#
#   scripts/update.sh <chart-dir> <tag> '<json array of yq paths>' [repository-path repository]
#
# Example: update.sh charts/courier v2026.08.1-release-e1f4018 '[".application.deployment.container.image.tag"]'
# The tag is always written as a string.
set -euo pipefail

chart="${1:?usage: $0 <chart-dir> <tag> <json paths> [repository-path repository]}"
tag="${2:?usage: $0 <chart-dir> <tag> <json paths> [repository-path repository]}"
paths="${3:?usage: $0 <chart-dir> <tag> <json paths> [repository-path repository]}"
file="${chart%/}/values.yaml"
[ -f "${file}" ] || { echo "::error::${file} not found" >&2; exit 1; }

n=0
while IFS= read -r p; do
  [ -n "${p}" ] || continue
  TAG="${tag}" yq -i "${p} = strenv(TAG)" "${file}"
  echo "${file}: ${p} = ${tag}"
  n=$((n + 1))
done < <(jq -r '.[]' <<<"${paths}")
[ "${n}" -gt 0 ] || { echo "::error::no image tag path given" >&2; exit 1; }

if [ -n "${4:-}" ] && [ -n "${5:-}" ]; then
  REPO="${5}" yq -i "${4} = strenv(REPO)" "${file}"
  echo "${file}: ${4} = ${5}"
fi
