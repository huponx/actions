#!/usr/bin/env bash
# End-to-end test of the argocd-manifest-diff scripts without GitHub: a local Helm chart, a git
# history with one Application changed, a local bare repository standing in for the Pages repo.
#   bash tests/argocd-manifest-diff.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts="${root}/.github/actions/argocd-manifest-diff/scripts"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
git_() { git -c user.email=ci@example.com -c user.name=ci "$@"; }

# Fixture: chart + Applications (the chart is a local path, helm ignores --version for those)
mkdir -p "${tmp}/repo/chart/templates" "${tmp}/repo/applications"
cd "${tmp}/repo"
cat > chart/Chart.yaml <<'YAML'
apiVersion: v2
name: demo
version: 1.0.0
YAML
cat > chart/templates/configmap.yaml <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo-config
data:
  greeting: {{ .Values.greeting | quote }}
YAML
cat > chart/templates/service.yaml <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: demo
spec:
  ports:
    - port: {{ .Values.port }}
YAML
write_app() { # <name> <greeting> <revision>
  cat > "applications/$1.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $1
spec:
  source:
    repoURL: ./chart
    targetRevision: "$3"
    helm:
      valuesObject:
        greeting: $2
        port: 80
  destination:
    name: in-cluster
    namespace: demo
YAML
}
write_app demo hello 1.0.0
write_app gone hello 1.0.0
git init -q -b main && git_ add -A && git_ commit -qm base
base="$(git rev-parse HEAD)"
write_app demo "hello-world" 1.0.1      # changed
write_app fresh hi 1.0.0                # added
git rm -q applications/gone.yaml        # removed
git_ add -A && git_ commit -qm change

# 1. Report
BASE_SHA="${base}" WORK="${tmp}/work" DIFFS_PATH=diffs DIFFS_BASE_URL=https://example.test/site \
  bash "${scripts}/pr-diff.sh" >/dev/null
fail() { echo "FAIL: $*"; cat "${tmp}/work/comment.md"; exit 1; }
[ "$(cat "${tmp}/work/changed")" = "3" ] || fail "expected 3 changed applications"
grep -q 'ConfigMap/demo-config' "${tmp}/work/comment.md" || fail "changed ConfigMap missing"
grep -q '| Changed |' "${tmp}/work/comment.md" || fail "no Changed row"
grep -q '| Added |' "${tmp}/work/comment.md" || fail "no Added row"
grep -q 'Removed (pruned by ArgoCD)' "${tmp}/work/comment.md" || fail "no Removed row"
grep -q 'https://example.test/site/demo/1.0.0...1.0.1.html' "${tmp}/work/urls.txt" || fail "html url missing"
[ -s "${tmp}/work/pages/diffs/demo/1.0.0...1.0.1.html" ] || fail "html page missing"
page="${tmp}/work/pages/diffs/demo/1.0.0...1.0.1.html"
grep -q greeting "${page}" || fail "html does not contain the change"
grep -q world "${page}" || fail "html does not contain the change"
grep -q '^<!-- argocd-manifest-diff -->' "${tmp}/work/comment.md" || fail "marker missing"
echo "ok report"

# 2. Publish to a local bare repo, twice (the second run is a no-op), the site folder only
git init -q --bare -b main "${tmp}/pages.git"
git clone -q "${tmp}/pages.git" "${tmp}/seed" 2>/dev/null
( cd "${tmp}/seed" && git checkout -q -B main && echo keep > README.md && git_ add -A && git_ commit -qm seed && git push -q origin main )
for i in 1 2; do
  DIFFS_GIT_URL="${tmp}/pages.git" DIFFS_PATH=diffs bash "${scripts}/publish-pages.sh" "${tmp}/work/pages" "test ${i}" >/dev/null 2>&1
done
git clone -q "${tmp}/pages.git" "${tmp}/check" 2>/dev/null
[ -f "${tmp}/check/README.md" ] || fail "publish removed an unrelated file"
[ -f "${tmp}/check/diffs/demo/1.0.0...1.0.1.html" ] || fail "page not published"
[ -f "${tmp}/check/diffs/index.html" ] || fail "index not generated"
[ "$(git -C "${tmp}/check" rev-list --count HEAD)" = "2" ] || fail "second publish created a commit"
echo "ok publish"
