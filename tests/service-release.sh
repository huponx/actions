#!/usr/bin/env bash
# Test create-prerelease (version rule) and create-deployment-pr (local bare repository, fake gh).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
next="${here}/.github/actions/create-prerelease/scripts/next-version.sh"
deploy="${here}/.github/actions/create-deployment-pr/scripts/deploy-pr.sh"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

get() { sed -n "s/^$1=//p" <<<"$2"; }
rel() { echo "$1" > "${tmp}/rel.json"; bash "${next}" "${tmp}/rel.json" "$2" "$3" "$4"; }

o=$(rel '[]' 2026 8 aaa1111)
[ "$(get tag "${o}")" = "v2026.08.1-release-aaa1111" ] || fail "first release of the month: ${o}"
[ "$(get exists "${o}")" = "false" ] || fail "exists"

R='[{"tag_name":"v2026.08.1-release-aaa1111","prerelease":true,"draft":false}]'
o=$(rel "${R}" 2026 8 bbb2222)
[ "$(get tag "${o}")" = "v2026.08.1-release-bbb2222" ] || fail "unpublished pre-release keeps N: ${o}"
[ "$(get superseded "${o}")" = "v2026.08.1-release-aaa1111" ] || fail "superseded: ${o}"

o=$(rel "${R}" 2026 8 aaa1111)
[ "$(get exists "${o}")" = "true" ] || fail "same commit must be idempotent: ${o}"
[ "$(get superseded "${o}")" = "" ] || fail "nothing to supersede on a re-run"

P='[{"tag_name":"v2026.08.1-release-aaa1111","prerelease":false,"draft":false}]'
o=$(rel "${P}" 2026 8 ccc3333)
[ "$(get tag "${o}")" = "v2026.08.2-release-ccc3333" ] || fail "published release bumps N: ${o}"
[ "$(get superseded "${o}")" = "" ] || fail "published release is never superseded"

M='[{"tag_name":"v2026.08.3-release-x","prerelease":false,"draft":false},{"tag_name":"v2026.08.1-release-y","prerelease":false,"draft":false}]'
o=$(rel "${M}" 2026 9 ddd4444)
[ "$(get tag "${o}")" = "v2026.09.1-release-ddd4444" ] || fail "new month restarts at 1: ${o}"
o=$(rel "${M}" 2026 8 eee5555)
[ "$(get tag "${o}")" = "v2026.08.4-release-eee5555" ] || fail "highest N wins: ${o}"
D='[{"tag_name":"v2026.08.1-release-aaa1111","prerelease":true,"draft":true}]'
o=$(rel "${D}" 2026 8 fff6666)
[ "$(get tag "${o}")" = "v2026.08.1-release-fff6666" ] || fail "drafts ignored: ${o}"
echo "ok prerelease"

# --- create-deployment-pr
bare="${tmp}/mm-deploy.git"
git init -q --bare -b main "${bare}"
seed="${tmp}/seed"
git clone -q "${bare}" "${seed}" 2>/dev/null
mkdir -p "${seed}/applications/dev"
cat > "${seed}/applications/dev/courier.yaml" <<'Y'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: courier
spec:
  source:
    repoURL: oci://ghcr.io/huponx/charts/courier
    targetRevision: "1.20260812.51-main-9a3c2d1"
Y
git -C "${seed}" add -A
git -C "${seed}" -c user.name=t -c user.email=t@t commit -q -m init
git -C "${seed}" push -q origin HEAD:main

mkdir -p "${tmp}/bin" "${tmp}/gh"
echo '[]' > "${tmp}/gh/prs.json"
cat > "${tmp}/bin/gh" <<'FAKE'
#!/usr/bin/env bash
# Fake gh: PR state in $FAKE_GH/prs.json, every call logged.
echo "$*" >> "${FAKE_GH}/calls.log"
case "$1 $2" in
  "pr list") cat "${FAKE_GH}/prs.json" ;;
  "pr create")
    head=""; while [ $# -gt 0 ]; do [ "$1" = "--head" ] && head="$2"; shift; done
    n=$(( $(jq length "${FAKE_GH}/prs.json") + 1 ))
    jq --arg h "${head}" --argjson n "${n}" '. + [{number:$n, url:("https://example/pr/" + ($n|tostring)), headRefName:$h}]' "${FAKE_GH}/prs.json" > "${FAKE_GH}/p.tmp"
    mv "${FAKE_GH}/p.tmp" "${FAKE_GH}/prs.json"
    echo "https://example/pr/${n}" ;;
  "pr close")
    jq --arg u "$3" 'map(select(.url != $u))' "${FAKE_GH}/prs.json" > "${FAKE_GH}/p.tmp"; mv "${FAKE_GH}/p.tmp" "${FAKE_GH}/prs.json" ;;
  *) : ;;
esac
FAKE
chmod +x "${tmp}/bin/gh"

run() {   # version [env overrides...]
  local v="$1"; shift
  env PATH="${tmp}/bin:${PATH}" FAKE_GH="${tmp}/gh" REPO=huponx/mm-deploy GIT_URL="${bare}" TOKEN=secret \
    FILE=applications/dev/courier.yaml VERSION="${v}" APP=courier ENV_NAME=dev LABELS='["automerge"]' \
    REVIEWERS='["octocat"]' AUTOMERGE=true "$@" bash "${deploy}" 2>/dev/null
}
show() { git -C "${bare}" show "$1:applications/dev/courier.yaml" | yq '.spec.source.targetRevision'; }

v1="1.20260813.57-main-e1f4018"
o=$(run "${v1}")
[ "$(get changed "${o}")" = "true" ] || fail "changed: ${o}"
[ "$(get branch "${o}")" = "deploy/courier/dev/${v1}" ] || fail "branch: ${o}"
[ "$(get pr-url "${o}")" = "https://example/pr/1" ] || fail "pr url: ${o}"
[ "$(show "deploy/courier/dev/${v1}")" = "${v1}" ] || fail "targetRevision on the branch"
[ "$(show main)" = "1.20260812.51-main-9a3c2d1" ] || fail "main must stay untouched"
grep -q -- '--label automerge' "${tmp}/gh/calls.log" || fail "label not passed"
grep -q 'label create automerge' "${tmp}/gh/calls.log" || fail "label not ensured"
grep -q -- '--add-reviewer octocat' "${tmp}/gh/calls.log" || fail "reviewer"
grep -q 'pr merge .* --auto --squash' "${tmp}/gh/calls.log" || fail "auto-merge"
echo "ok create"

: > "${tmp}/gh/calls.log"
o=$(run "${v1}")
[ "$(get pr-url "${o}")" = "https://example/pr/1" ] || fail "re-run must reuse the PR: ${o}"
grep -q 'pr create' "${tmp}/gh/calls.log" && fail "re-run created a second PR"
grep -q 'pr edit https://example/pr/1' "${tmp}/gh/calls.log" || fail "re-run must edit the PR"
[ "$(jq length "${tmp}/gh/prs.json")" = 1 ] || fail "exactly one PR after a re-run"
echo "ok idempotent"

v2="1.20260813.58-main-0d0d0d0"
o=$(run "${v2}")
[ "$(get pr-url "${o}")" = "https://example/pr/2" ] || fail "new version opens a new PR: ${o}"
[ "$(jq -r '.[].headRefName' "${tmp}/gh/prs.json")" = "deploy/courier/dev/${v2}" ] || fail "older deploy PR must be closed: $(jq -c . "${tmp}/gh/prs.json")"
echo "ok supersede"

git -C "${bare}" update-ref refs/heads/main "$(git -C "${bare}" rev-parse "deploy/courier/dev/${v2}")" 2>/dev/null || git -C "${bare}" update-ref refs/heads/main "$(git -C "${bare}" rev-parse "refs/heads/deploy/courier/dev/${v2}")"
o=$(run "${v2}")
[ "$(get changed "${o}")" = "false" ] || fail "already deployed version must be a no-op: ${o}"
if run "${v2}" FILE=applications/dev/missing.yaml >/dev/null; then fail "missing file accepted"; fi
echo "ok no-op"
