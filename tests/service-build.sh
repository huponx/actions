#!/usr/bin/env bash
# Test update-chart-metadata, update-deployment-values and the helm part of helm-package-push (no push).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
a="${here}/.github/actions"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "${tmp}/charts/demo/templates" "${tmp}/charts/demo/ci"
cat > "${tmp}/charts/demo/Chart.yaml" <<'Y'
apiVersion: v2
name: demo
version: 0.0.0
appVersion: "0.0.0"
Y
cat > "${tmp}/charts/demo/values.yaml" <<'Y'
application:
  deployment:
    container:
      image:
        repository: huponx/demo
        tag: "0.0.0"
other:
  tag: keep
Y
cat > "${tmp}/charts/demo/templates/cm.yaml" <<'Y'
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo
data:
  tag: {{ .Values.application.deployment.container.image.tag | quote }}
  app: {{ .Chart.AppVersion | quote }}
Y
echo 'other: {tag: ci}' > "${tmp}/charts/demo/ci/ci.yaml"

ver="v2026.08.1-release-e1f4018"
bash "${a}/update-chart-metadata/scripts/update.sh" "${tmp}/charts/demo" "${ver}" >/dev/null
[ "$(yq '.version' "${tmp}/charts/demo/Chart.yaml")" = "${ver}" ] || fail "chart version"
[ "$(yq '.appVersion' "${tmp}/charts/demo/Chart.yaml")" = "${ver}" ] || fail "appVersion"
echo "ok chart-metadata"

bash "${a}/update-deployment-values/scripts/update.sh" "${tmp}/charts/demo" "${ver}" '[".application.deployment.container.image.tag"]' \
  ".application.deployment.container.image.repository" "ghcr.io/huponx/demo" >/dev/null
[ "$(yq '.application.deployment.container.image.tag' "${tmp}/charts/demo/values.yaml")" = "${ver}" ] || fail "image tag"
[ "$(yq '.application.deployment.container.image.repository' "${tmp}/charts/demo/values.yaml")" = "ghcr.io/huponx/demo" ] || fail "repository"
[ "$(yq '.other.tag' "${tmp}/charts/demo/values.yaml")" = "keep" ] || fail "other values untouched"
# a numeric-looking tag must stay a string
bash "${a}/update-deployment-values/scripts/update.sh" "${tmp}/charts/demo" "1234" '[".application.deployment.container.image.tag"]' >/dev/null
[ "$(yq '.application.deployment.container.image.tag | tag' "${tmp}/charts/demo/values.yaml")" = "!!str" ] || fail "tag must be a string"
bash "${a}/update-deployment-values/scripts/update.sh" "${tmp}/charts/demo" "${ver}" '[".application.deployment.container.image.tag"]' >/dev/null
if bash "${a}/update-deployment-values/scripts/update.sh" "${tmp}/charts/demo" "${ver}" '[]' >/dev/null 2>&1; then fail "empty paths accepted"; fi
echo "ok deployment-values"

out=$(bash "${a}/helm-package-push/scripts/package.sh" "${tmp}/charts/demo" "${ver}" oci://example.invalid/charts "${tmp}/dist" false 2>/dev/null)
grep -qx 'pushed=false' <<<"${out}" || fail "package output: ${out}"
grep -qx "ref=oci://example.invalid/charts/demo:${ver}" <<<"${out}" || fail "ref: ${out}"
[ -f "${tmp}/dist/demo-${ver}.tgz" ] || fail "tgz missing"
if bash "${a}/helm-package-push/scripts/package.sh" "${tmp}/charts/demo" "v9.9.9" oci://example.invalid/charts "${tmp}/dist" false >/dev/null 2>&1; then fail "version mismatch accepted"; fi
echo "ok package"
