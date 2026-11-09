#!/usr/bin/env bash
# Publish generated HTML pages to the GitHub Pages repository and refresh its index.html.
#
#   scripts/publish-pages.sh <pages_dir> <commit message>
#
# Environment:
#   DIFFS_REPO     owner/repo of the pages repository (required unless DIFFS_GIT_URL is set)
#   DIFFS_BRANCH   branch served by Pages (default main)
#   DIFFS_PATH     folder inside the repo (default empty = repo root); only this folder is touched
#   DIFFS_TOKEN    token with Contents read/write on DIFFS_REPO (BOT_TOKEN in CI)
#   DIFFS_GIT_URL  override the clone URL (tests)
#   KEEP_DAYS      delete pages older than this many days (default 90, 0 = keep all)
set -euo pipefail

pages="${1:?usage: $0 <pages_dir> <commit message>}"
msg="${2:?usage: $0 <pages_dir> <commit message>}"
pages=$(cd "${pages}" && pwd)   # absolute: the script changes directory
branch="${DIFFS_BRANCH:-main}"
subdir="${DIFFS_PATH:-}"
keep_days="${KEEP_DAYS:-90}"

url="${DIFFS_GIT_URL:-}"
if [ -z "${url}" ]; then
  : "${DIFFS_REPO:?DIFFS_REPO is required}" "${DIFFS_TOKEN:?DIFFS_TOKEN is required}"
  url="https://x-access-token:${DIFFS_TOKEN}@github.com/${DIFFS_REPO}.git"
fi

if [ -z "$(find "${pages}" -type f -name '*.html' 2>/dev/null | head -n 1)" ]; then
  echo "no pages to publish"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
git clone --quiet --depth 1 --branch "${branch}" "${url}" "${work}/repo"
cd "${work}/repo"
git config user.name "argocd-manifest-diff-bot"
git config user.email "argocd-manifest-diff-bot@users.noreply.github.com"

root="${subdir:-.}"
mkdir -p "${root}"

regenerate_index() {
  python3 - "${root}" <<'PY'
import html, os, sys, time
root = sys.argv[1]
rows = []
for dp, dn, fn in os.walk(root):
    dn[:] = [d for d in dn if not d.startswith(".")]
    for f in fn:
        if f.endswith(".html") and not (dp == root and f == "index.html"):
            p = os.path.join(dp, f)
            rows.append((os.path.relpath(p, root), os.path.getmtime(p)))
rows.sort(key=lambda r: r[1], reverse=True)
out = ['<!doctype html><meta charset="utf-8"><title>ArgoCD manifest diffs</title>',
       '<style>body{font:15px/1.6 system-ui,sans-serif;margin:2rem auto;max-width:60rem}td{padding:.2rem .8rem}</style>',
       '<h1>ArgoCD manifest diffs</h1><table>']
for rel, mt in rows:
    when = time.strftime("%Y-%m-%d %H:%M", time.gmtime(mt))
    out.append(f'<tr><td>{when} UTC</td><td><a href="{html.escape(rel)}">{html.escape(rel)}</a></td></tr>')
out.append("</table>")
open(os.path.join(root, "index.html"), "w", encoding="utf-8").write("\n".join(out))
PY
}

for attempt in 1 2 3 4; do
  cp -R "${pages}/${subdir:+${subdir}/}." "${root}/"
  if [ "${keep_days}" != "0" ]; then
    find "${root}" -type f -name '*.html' ! -name index.html -mtime "+${keep_days}" -delete 2>/dev/null || true
  fi
  regenerate_index
  git add -A "${root}"
  if git diff --cached --quiet; then echo "pages repository already up to date"; exit 0; fi
  git commit --quiet -m "${msg}"
  if git push --quiet origin "HEAD:${branch}"; then echo "published"; exit 0; fi
  echo "push rejected (attempt ${attempt}), rebasing"
  git reset --quiet --hard "origin/${branch}" 2>/dev/null || true
  git fetch --quiet origin "${branch}"
  git reset --quiet --hard "origin/${branch}"
done
echo "::error::could not push the pages after several attempts" >&2
exit 1
