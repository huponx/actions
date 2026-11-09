#!/usr/bin/env bash
# Create or update the sticky pull request comment identified by MARKER.
#
# Environment: GH_TOKEN, BODY_FILE, MARKER, PR_NUMBER, GITHUB_REPOSITORY,
#              CREATE (default true), FAIL_ON_ERROR (default false), IS_FORK (default false).
# Prints "action=created|updated|skipped" on stdout (the action appends it to GITHUB_OUTPUT).
# Needs: gh.
set -euo pipefail

body="${BODY_FILE:?BODY_FILE is required}"
marker="${MARKER:?MARKER is required}"
pr="${PR_NUMBER:-}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

skip() { echo "::notice::$1" >&2; echo "action=skipped"; exit 0; }

[ -f "${body}" ] || { echo "::error::body file ${body} not found" >&2; exit 1; }
grep -qF -- "${marker}" "${body}" || { echo "::error::the body does not contain the marker '${marker}'" >&2; exit 1; }
[ -n "${pr}" ] || skip "no pull request: comment skipped"
[ "${IS_FORK:-false}" != "true" ] || skip "fork pull request (read-only token): comment skipped"

write() {
  local id
  id=$(gh api "repos/${repo}/issues/${pr}/comments" --paginate \
         --jq ".[] | select(.body | contains(\"${marker//\"/\\\"}\")) | .id" | head -n 1)
  if [ -n "${id}" ]; then
    gh api -X PATCH "repos/${repo}/issues/comments/${id}" -F body=@"${body}" > /dev/null
    echo "action=updated"
  elif [ "${CREATE:-true}" = "true" ]; then
    gh api -X POST "repos/${repo}/issues/${pr}/comments" -F body=@"${body}" > /dev/null
    echo "action=created"
  else
    echo "action=skipped"
  fi
}

if out=$(write); then
  echo "${out}"
else
  if [ "${FAIL_ON_ERROR:-false}" = "true" ]; then
    echo "::error::could not write the pull request comment" >&2; exit 1
  fi
  echo "::warning::could not write the pull request comment (token needs pull-requests write)" >&2
  echo "action=skipped"
fi
