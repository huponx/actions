#!/usr/bin/env bash
# Compare two directories produced by render-app.sh.
#
#   scripts/diff-render.sh <old_dir> <new_dir> <out_dir>
#
# Writes into out_dir:
#   summary.md   markdown table: Added / Removed / Changed resources (Kind/namespace/name)
#   changes.diff git-style unified diff of all resources (input for diff2html)
# Exit code is always 0 when the comparison itself worked (a diff is not an error).
set -euo pipefail

old="${1:?usage: $0 <old_dir> <new_dir> <out_dir>}"
new="${2:?usage: $0 <old_dir> <new_dir> <out_dir>}"
out="${3:?usage: $0 <old_dir> <new_dir> <out_dir>}"
mkdir -p "${out}" "${old}" "${new}"

label() { # Kind_ns_name.yaml -> Kind/ns/name
  local b="${1%.yaml}"
  local kind="${b%%_*}"
  local rest="${b#*_}"
  local ns="${rest%%_*}"
  local name="${rest#*_}"
  if [ "${ns}" = "-" ]; then echo "${kind}/${name}"; else echo "${kind}/${ns}/${name}"; fi
}

added=(); removed=(); changed=()
for f in $(cd "${new}" && ls); do
  if [ ! -f "${old}/${f}" ]; then added+=("${f}")
  elif ! cmp -s "${old}/${f}" "${new}/${f}"; then changed+=("${f}"); fi
done
for f in $(cd "${old}" && ls); do
  [ -f "${new}/${f}" ] || removed+=("${f}")
done

{
  echo "| Change | Resource |"
  echo "|--------|----------|"
  for f in "${added[@]+"${added[@]}"}";   do echo "| Added | \`$(label "${f}")\` |"; done
  for f in "${removed[@]+"${removed[@]}"}"; do echo "| Removed (pruned by ArgoCD) | \`$(label "${f}")\` |"; done
  for f in "${changed[@]+"${changed[@]}"}"; do echo "| Changed | \`$(label "${f}")\` |"; done
  if [ $(( ${#added[@]} + ${#removed[@]} + ${#changed[@]} )) -eq 0 ]; then
    echo "| none | No difference in rendered manifests |"
  fi
} > "${out}/summary.md"

# Compare through two temp dirs named a/ and b/ so the diff headers read like a GitHub diff.
# git diff --no-index exits 1 when there are differences.
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
cp -R "${old}" "${tmp}/a"
cp -R "${new}" "${tmp}/b"
( cd "${tmp}" && git diff --no-index --no-color a b ) > "${out}/changes.diff" || true
# The temp dirs add a second a/ and b/ level to every path: drop it.
sed -i.bak -E \
  -e 's#^diff --git a/(a|b)/([^ ]+) b/(a|b)/#diff --git a/\2 b/#' \
  -e 's#^(--- )a/(a|b)/#\1a/#' \
  -e 's#^(\+\+\+ )b/(a|b)/#\1b/#' "${out}/changes.diff"
rm -f "${out}/changes.diff.bak"

echo "added=${#added[@]} removed=${#removed[@]} changed=${#changed[@]}"
