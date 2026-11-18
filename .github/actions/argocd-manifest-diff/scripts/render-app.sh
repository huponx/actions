#!/usr/bin/env bash
# Render the chart of one ArgoCD Application into one normalised file per resource.
#
#   scripts/render-app.sh <application.yaml|-> <out_dir>
#
# "-" (or a missing file) renders nothing: an empty out_dir, used as the "old" side of a new app.
# Files are named <Kind>_<namespace>_<name>.yaml with sorted keys, so they diff cleanly.
# Needs: helm, yq (mikefarah v4). For private charts run `helm registry login` first.
set -euo pipefail

app="${1:?usage: $0 <application.yaml|-> <out_dir>}"
out="${2:?usage: $0 <application.yaml|-> <out_dir>}"

rm -rf "${out}"
mkdir -p "${out}"
if [ "${app}" = "-" ] || [ ! -s "${app}" ]; then
  exit 0
fi

name=$(yq '.metadata.name' "${app}")
repo=$(yq '.spec.source.repoURL' "${app}")
rev=$(yq '.spec.source.targetRevision' "${app}")
release=$(yq '.spec.source.helm.releaseName // .metadata.name' "${app}")
namespace=$(yq '.spec.destination.namespace // "default"' "${app}")

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
yq '.spec.source.helm.valuesObject // {}' "${app}" > "${tmp}/values.yaml"

if ! helm template "${release}" "${repo}" --version "${rev}" --namespace "${namespace}" \
      -f "${tmp}/values.yaml" > "${tmp}/rendered.yaml" 2> "${tmp}/helm.err"; then
  echo "::error::helm template failed for ${name} (${repo}:${rev})"
  cat "${tmp}/helm.err" >&2
  echo "Hint: the chart must exist and be readable (public package, or the repo has Read access in the package settings)." >&2
  exit 1
fi

# Split into one file per resource, then normalise.
(cd "${tmp}" && yq ea -s '"doc_" + (document_index | tostring)' rendered.yaml)
for f in "${tmp}"/doc_*.yml; do
  [ -e "${f}" ] || continue
  kind=$(yq '.kind // ""' "${f}")
  [ -n "${kind}" ] || continue
  rname=$(yq '.metadata.name' "${f}")
  rns=$(yq '.metadata.namespace // "-"' "${f}")
  # Drop the "# Source:" comment and the document separator helm adds: they only add noise to a diff.
  yq -P 'sort_keys(..)' "${f}" | sed -e '/^# Source: /d' -e '/^---$/d' > "${out}/${kind}_${rns}_${rname}.yaml"
done
echo "rendered ${name}@${rev}: $(find "${out}" -type f | wc -l | tr -d ' ') resource(s)"
