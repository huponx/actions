#!/usr/bin/env bash
# Open (or update) the pull request that deploys a version: edit one file of the deployment repository with
# yq, push branch deploy/<app>/<env>/<version>, create or refresh the PR, close the older open deploy PRs of
# the same app and env.
#
# Environment (all strings; lists are JSON arrays):
#   REPO         owner/name of the deployment repository          (required)
#   BASE_BRANCH  branch to branch from and merge into             (default main)
#   FILE         file to edit, relative to the repository root    (required)
#   SET          yq paths that receive VERSION                    (default [".spec.source.targetRevision"])
#   VERSION APP ENV_NAME                                          (required)
#   REVIEWERS LABELS  JSON arrays, optional
#   AUTOMERGE    true = gh pr merge --auto --squash after creating
#   TOKEN        token with contents + pull-requests write on REPO (required)
#   GIT_URL      clone URL override (tests); default https://x-access-token:TOKEN@github.com/REPO.git
#   SLACK_WEBHOOK_URL  optional, one message with the PR link
#   SOURCE_REPO RUN_URL  optional, mentioned in the PR body
# Idempotent: the same version updates the same branch and PR. Prints pr-url=, branch=, changed=.
# Needs git, gh, yq, jq.
set -euo pipefail

repo="${REPO:?REPO is required}"
base="${BASE_BRANCH:-main}"
file="${FILE:?FILE is required}"
set_paths="${SET:-[\".spec.source.targetRevision\"]}"
version="${VERSION:?VERSION is required}"
app="${APP:?APP is required}"
env_name="${ENV_NAME:?ENV_NAME is required}"
reviewers="${REVIEWERS:-[]}"
labels="${LABELS:-[]}"
automerge="${AUTOMERGE:-false}"
token="${TOKEN:?TOKEN is required}"
url="${GIT_URL:-https://x-access-token:${token}@github.com/${repo}.git}"
branch="deploy/${app}/${env_name}/${version}"
title="chore(${app}): bump chart to ${version} (${env_name})"

export GH_TOKEN="${token}"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

git clone --quiet --depth 1 --branch "${base}" "${url}" "${tmp}/repo" 2>&1 | sed "s#${token}#***#g" >&2
cd "${tmp}/repo"
git config user.name "${GIT_AUTHOR_NAME:-deployment-bot}"
git config user.email "${GIT_AUTHOR_EMAIL:-deployment-bot@users.noreply.github.com}"
git checkout -q -B "${branch}"

[ -f "${file}" ] || { echo "::error::${file} does not exist in ${repo}@${base}" >&2; exit 1; }
while IFS= read -r p; do
  [ -n "${p}" ] || continue
  V="${version}" yq -i "${p} = strenv(V)" "${file}"
done < <(jq -r '.[]' <<<"${set_paths}")

if git diff --quiet; then
  echo "::notice::${file} on ${base} already has ${version}: nothing to deploy" >&2
  echo "changed=false"; echo "branch=${branch}"; echo "pr-url="
  exit 0
fi

git commit -q -am "chore(${app}): bump chart to ${version} (${env_name})"
git push --quiet --force origin "${branch}" 2>&1 | sed "s#${token}#***#g" >&2

body="Deploys \`${app}\` **${version}** to \`${env_name}\` (\`${file}\`: $(jq -r 'join(", ")' <<<"${set_paths}"))."
[ -z "${SOURCE_REPO:-}" ] || body="${body}"$'\n\n'"Source: https://github.com/${SOURCE_REPO}"
[ -z "${RUN_URL:-}" ] || body="${body}"$'\n'"Run: ${RUN_URL}"

open_prs=$(gh pr list --repo "${repo}" --state open --json number,url,headRefName)
pr_url=$(jq -r --arg b "${branch}" '[.[] | select(.headRefName == $b)] | .[0].url // ""' <<<"${open_prs}")

label_args=()
while IFS= read -r l; do
  [ -n "${l}" ] || continue
  gh label create "${l}" --repo "${repo}" --color 0e8a16 >/dev/null 2>&1 || true
  label_args+=(--label "${l}")
done < <(jq -r '.[]' <<<"${labels}")

if [ -z "${pr_url}" ]; then
  pr_url=$(gh pr create --repo "${repo}" --base "${base}" --head "${branch}" --title "${title}" --body "${body}" "${label_args[@]+"${label_args[@]}"}")
  echo "created ${pr_url}" >&2
else
  gh pr edit "${pr_url}" --repo "${repo}" --title "${title}" --body "${body}" "${label_args[@]+"${label_args[@]}"}" >/dev/null
  echo "updated ${pr_url}" >&2
fi

rev=$(jq -r 'join(",")' <<<"${reviewers}")
if [ -n "${rev}" ]; then
  gh pr edit "${pr_url}" --repo "${repo}" --add-reviewer "${rev}" >/dev/null 2>&1 || echo "::warning::could not request reviewers ${rev}" >&2
fi
if [ "${automerge}" = "true" ]; then
  gh pr merge "${pr_url}" --repo "${repo}" --auto --squash >/dev/null 2>&1 || echo "::warning::could not enable auto-merge on ${pr_url}" >&2
fi

# Older open deploy PRs of the same app and env are superseded by this one.
while IFS= read -r old; do
  [ -n "${old}" ] || continue
  gh pr close "${old}" --repo "${repo}" --delete-branch --comment "Superseded by ${pr_url}" >/dev/null 2>&1 || true
done < <(jq -r --arg prefix "deploy/${app}/${env_name}/" --arg b "${branch}" '.[] | select((.headRefName | startswith($prefix)) and .headRefName != $b) | .url' <<<"${open_prs}")

if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  curl -fsS -X POST -H 'Content-type: application/json' \
    --data "$(jq -n --arg t "Deployment PR for ${app} ${version} (${env_name}): ${pr_url}" '{text: $t}')" \
    "${SLACK_WEBHOOK_URL}" >/dev/null || echo "::warning::Slack notification failed" >&2
fi

echo "changed=true"; echo "branch=${branch}"; echo "pr-url=${pr_url}"
