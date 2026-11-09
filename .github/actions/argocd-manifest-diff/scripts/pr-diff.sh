#!/usr/bin/env bash
# Build the "what changes in the cluster" report for the Applications changed since BASE_SHA.
#
#   BASE_SHA=<sha> scripts/pr-diff.sh
#
# Environment:
#   BASE_SHA          commit to compare against (required)
#   APPLICATIONS_PATH folder with the Application manifests (default applications)
#   WORK              work dir (default .diff-work)
#   DIFFS_PATH        folder inside the pages repo (default empty)
#   DIFFS_BASE_URL    public base URL of the pages site (required to print HTML links)
#   RUN_URL           link to the workflow run (optional, shown in the comment)
#
# Output:
#   $WORK/comment.md          markdown for the sticky PR comment
#   $WORK/pages/...           HTML pages to publish (relative to the pages repo root)
#   $WORK/urls.txt            one public URL per generated page
#   $WORK/changed             number of changed Application files
set -euo pipefail

base="${BASE_SHA:?BASE_SHA is required}"
work="${WORK:-.diff-work}"
apps_path="${APPLICATIONS_PATH:-applications}"
apps_path="${apps_path%/}"
diffs_path="${DIFFS_PATH:-}"
base_url="${DIFFS_BASE_URL:-}"
base_url="${base_url%/}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rm -rf "${work}"
mkdir -p "${work}/pages"
: > "${work}/urls.txt"

safe() { tr -c 'A-Za-z0-9._\n-' '_' <<<"$1"; }   # revisions may hold characters unfit for file names

# Changed, added and deleted Application files.
files=()
while IFS= read -r line; do [ -n "${line}" ] && files+=("${line}"); done < <(git diff --no-renames --name-only --diff-filter=ACMD "${base}" HEAD -- "${apps_path}/*.yaml")
echo "${#files[@]}" > "${work}/changed"

limit=${DIFF_PREVIEW_LINES:-300}
{
  echo "<!-- argocd-manifest-diff -->"
  echo "## Cluster diff"
  echo
} > "${work}/comment.md"

if [ "${#files[@]}" -eq 0 ]; then
  echo "No Application changed in this PR." >> "${work}/comment.md"
  exit 0
fi

for f in "${files[@]}"; do
  app=$(basename "${f}" .yaml)
  dir="${work}/${app}"
  mkdir -p "${dir}"

  if git cat-file -e "${base}:${f}" 2>/dev/null; then git show "${base}:${f}" > "${dir}/old.yaml"; else : > "${dir}/old.yaml"; fi
  if [ -f "${f}" ]; then cp "${f}" "${dir}/new.yaml"; else : > "${dir}/new.yaml"; fi

  old_rev=""; new_rev=""
  [ -s "${dir}/old.yaml" ] && old_rev=$(yq '.spec.source.targetRevision // ""' "${dir}/old.yaml")
  [ -s "${dir}/new.yaml" ] && new_rev=$(yq '.spec.source.targetRevision // ""' "${dir}/new.yaml")

  {
    echo "### \`${app}\`"
    echo
    if [ ! -s "${dir}/old.yaml" ]; then echo "New application at \`${new_rev}\`."
    elif [ ! -s "${dir}/new.yaml" ]; then echo "Application removed (was \`${old_rev}\`): ArgoCD prunes everything below."
    elif [ "${old_rev}" = "${new_rev}" ]; then echo "\`targetRevision\` unchanged (\`${new_rev}\`), only values or other fields changed."
    else echo "\`targetRevision\`: \`${old_rev}\` -> \`${new_rev}\`"; fi
    echo
  } >> "${work}/comment.md"

  if ! "${here}/render-app.sh" "${dir}/old.yaml" "${dir}/old" > "${dir}/render.log" 2>&1 \
     || ! "${here}/render-app.sh" "${dir}/new.yaml" "${dir}/new" >> "${dir}/render.log" 2>&1; then
    {
      echo "Could not render the chart, so no diff is available:"
      echo
      echo '```'
      tail -n 15 "${dir}/render.log"
      echo '```'
      echo
    } >> "${work}/comment.md"
    continue
  fi

  "${here}/diff-render.sh" "${dir}/old" "${dir}/new" "${dir}/out" > /dev/null
  { cat "${dir}/out/summary.md"; echo; } >> "${work}/comment.md"

  if [ ! -s "${dir}/out/changes.diff" ]; then continue; fi

  # HTML page
  if [ -z "${old_rev}" ]; then page="${app}/new-$(safe "${new_rev}").html"
  elif [ -z "${new_rev}" ]; then page="${app}/removed-$(safe "${old_rev}").html"
  elif [ "${old_rev}" = "${new_rev}" ]; then page="${app}/$(safe "${new_rev}")-values-$(git rev-parse --short HEAD).html"
  else page="${app}/$(safe "${old_rev}")...$(safe "${new_rev}").html"; fi
  rel="${diffs_path:+${diffs_path}/}${page}"
  "${here}/diff-html.sh" "${dir}/out/changes.diff" "${work}/pages/${rel}" "${app}: ${old_rev:-none} -> ${new_rev:-removed}"

  if [ -n "${base_url}" ]; then
    url="${base_url}/${page}"
    echo "${url}" >> "${work}/urls.txt"
    echo "**[Open the side-by-side diff](${url})** (the page can take up to a minute to appear after the first push)" >> "${work}/comment.md"
    echo >> "${work}/comment.md"
  fi

  # Service repository links (only when both revisions exist).
  if [ -s "${dir}/new.yaml" ]; then
    "${here}/compare-links.sh" "${dir}/new.yaml" "${old_rev}" "${new_rev}" >> "${work}/comment.md" 2>/dev/null || true
    echo >> "${work}/comment.md"
  fi

  total=$(wc -l < "${dir}/out/changes.diff" | tr -d ' ')
  shown=$(( total < limit ? total : limit ))
  {
    echo "<details><summary>Rendered manifest diff (first ${shown} of ${total} lines)</summary>"
    echo
    echo '```diff'
    head -n "${shown}" "${dir}/out/changes.diff"
    echo '```'
    echo
    echo "</details>"
    echo
  } >> "${work}/comment.md"
done

[ -z "${RUN_URL:-}" ] || echo "_Generated by [this run](${RUN_URL})._" >> "${work}/comment.md"

# A PR comment is limited to 65536 characters: keep a margin.
max=60000
size=$(wc -c < "${work}/comment.md" | tr -d ' ')
if [ "${size}" -gt "${max}" ]; then
  head -c "${max}" "${work}/comment.md" > "${work}/comment.cut"
  { cat "${work}/comment.cut"; printf '\n\n_Comment truncated: open the side-by-side diff for the full change._\n'; } > "${work}/comment.md"
  rm -f "${work}/comment.cut"
fi
echo "report: ${work}/comment.md (${size} bytes)"
