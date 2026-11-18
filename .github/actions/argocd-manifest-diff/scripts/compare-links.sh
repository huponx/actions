#!/usr/bin/env bash
# Print markdown links to the GitHub compare views of the service repo between two chart revisions.
#
#   scripts/compare-links.sh <application.yaml> <old_rev> <new_rev>
#
# Source repo: annotation metadata.annotations["argocd-manifest-diff/source-repo"] (owner/repo),
#              fallback "<owner of the chart registry path>/<application name>".
# Commit of a revision: the trailing -<shortsha> of "1.20260813.4-main-e1f4018",
#                       else the tag "v<revision>", else the tag "<revision>".
# Unresolvable revisions produce a note instead of a broken link. Needs gh (GH_TOKEN) and yq.
set -euo pipefail

app="${1:?usage: $0 <application.yaml> <old_rev> <new_rev>}"
old_rev="${2:-}"
new_rev="${3:?usage: $0 <application.yaml> <old_rev> <new_rev>}"

name=$(yq '.metadata.name' "${app}")
repo=$(yq '.metadata.annotations."argocd-manifest-diff/source-repo" // ""' "${app}")
if [ -z "${repo}" ]; then
  chart_url=$(yq '.spec.source.repoURL' "${app}")          # oci://ghcr.io/<owner>/charts/<name>
  owner=$(sed -E 's#^oci://[^/]+/([^/]+)/.*#\1#' <<<"${chart_url}")
  repo="${owner}/${name}"
fi

resolve() { # <rev> -> prints the commit ref usable in a compare URL, or nothing
  local rev="$1" sha=""
  [ -n "${rev}" ] || return 0
  if [[ "${rev}" =~ -([0-9a-f]{7,40})$ ]]; then
    sha="${BASH_REMATCH[1]}"
    if gh api "repos/${repo}/commits/${sha}" --jq .sha >/dev/null 2>&1; then echo "${sha}"; return 0; fi
  fi
  for t in "v${rev}" "${rev}"; do
    if gh api "repos/${repo}/commits/${t}" --jq .sha >/dev/null 2>&1; then echo "${t}"; return 0; fi
  done
}

old_ref=$(resolve "${old_rev}")
new_ref=$(resolve "${new_rev}")

echo "Source repository: [\`${repo}\`](https://github.com/${repo})"
echo
if [ -z "${old_rev}" ]; then
  echo "- New application: no previous revision to compare."
elif [ -z "${old_ref}" ] || [ -z "${new_ref}" ]; then
  echo "- Compare links unavailable: could not map \`${old_rev}\` / \`${new_rev}\` to commits or tags of \`${repo}\`."
  echo "  Set the annotation \`argocd-manifest-diff/source-repo\` on the Application if the repository name differs."
else
  echo "- [Code diff \`${old_ref}..${new_ref}\`](https://github.com/${repo}/compare/${old_ref}..${new_ref}) (two dots: direct difference between the two commits)"
  echo "- [Commits \`${old_ref}...${new_ref}\`](https://github.com/${repo}/compare/${old_ref}...${new_ref}) (three dots: commits and changes since their common ancestor)"
fi
