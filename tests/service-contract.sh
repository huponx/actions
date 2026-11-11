#!/usr/bin/env bash
# Test retrieve-contract (validation, defaults) and resolve-env-config (merge, substitution, filters).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
retrieve="${here}/.github/actions/retrieve-contract/scripts/retrieve.sh"
resolve="${here}/.github/actions/resolve-env-config/scripts/resolve.sh"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "${tmp}/ci.yaml" <<'Y'
apps:
  - name: courier
    language: go
    cicd:
      jobs:
        containerize-and-package:
          image-name: courier
          dockerfile-path: build/courier/Dockerfile
          chart-path: charts/courier
          image-tag-paths: [.application.deployment.container.image.tag]
  - name: courier-worker
    language: go
    cicd:
      jobs:
        containerize-and-package:
          image-name: courier-worker
          dockerfile-path: build/courier-worker/Dockerfile
          chart-path: charts/courier-worker
          image-tag-paths: [.application.deployment.container.image.tag]
          trivy: { severity: "CRITICAL", ignore-unfixed: false, exit-code: 0 }
    create-deployment-pr:
      environments:
        dev: { labels: [worker-only] }
        staging: { enabled: false }
global:
  deploy:
    repo: huponx/mm-deploy
    base-branch: main
    file: "applications/{env}/{app}.yaml"
    reviewers: ["{actor}", "someone"]
    labels: [deploy]
    automerge: false
  environments:
    dev:        { workflows: [main], automerge: true, labels: [automerge] }
    staging:    { workflows: [staging], repo: huponx/mm-deploy-staging, set: [".spec.source.targetRevision", ".metadata.annotations.version"] }
    production: { workflows: [production], reviewers: [release-managers], enabled: false }
Y

out=$(bash "${retrieve}" "${tmp}/ci.yaml")
apps=$(sed -n 's/^apps=//p' <<<"${out}")
[ "$(jq length <<<"${apps}")" = 2 ] || fail "apps count"
[ "$(jq -r '.[0]."trivy-severity"' <<<"${apps}")" = "HIGH,CRITICAL" ] || fail "default severity"
[ "$(jq -r '.[0]."trivy-ignore-unfixed"' <<<"${apps}")" = "true" ] || fail "default ignore-unfixed"
[ "$(jq -r '.[1]."trivy-ignore-unfixed"' <<<"${apps}")" = "false" ] || fail "explicit ignore-unfixed false"
[ "$(jq -r '.[1]."trivy-fail"' <<<"${apps}")" = "false" ] || fail "exit-code 0 means report only"
[ "$(jq -r '.[0]."trivy-fail"' <<<"${apps}")" = "true" ] || fail "scan gates by default"
grep -qx 'environments=\["dev","staging","production"\]' <<<"${out}" || fail "environments: ${out}"
grep -qx 'count=2' <<<"${out}" || fail "count"
echo "ok retrieve"

# unknown keys fail
sed 's/image-name: courier$/image-name: courier\n          surprise: 1/' "${tmp}/ci.yaml" > "${tmp}/bad.yaml"
if bash "${retrieve}" "${tmp}/bad.yaml" >/dev/null 2>"${tmp}/err"; then fail "unknown key accepted"; fi
grep -q 'unknown key surprise' "${tmp}/err" || fail "unknown key message: $(cat "${tmp}/err")"
sed 's/^global:/globl:/' "${tmp}/ci.yaml" > "${tmp}/bad2.yaml"
if bash "${retrieve}" "${tmp}/bad2.yaml" >/dev/null 2>&1; then fail "unknown root key accepted"; fi
sed '/dockerfile-path: build\/courier\/Dockerfile/d' "${tmp}/ci.yaml" > "${tmp}/bad3.yaml"
if bash "${retrieve}" "${tmp}/bad3.yaml" >/dev/null 2>&1; then fail "missing required key accepted"; fi
echo "ok validation"

# languages: go, java and sql are accepted and listed once; anything else fails.
cat > "${tmp}/langs.yaml" <<'Y'
apps:
  - name: a
    language: sql
    cicd: { jobs: { containerize-and-package: { image-name: a, dockerfile-path: Dockerfile, chart-path: charts/a, image-tag-paths: [.t] } } }
  - name: b
    language: java
    cicd: { jobs: { containerize-and-package: { image-name: b, dockerfile-path: Dockerfile, chart-path: charts/b, image-tag-paths: [.t] } } }
  - name: c
    language: sql
    cicd: { jobs: { containerize-and-package: { image-name: c, dockerfile-path: Dockerfile, chart-path: charts/c, image-tag-paths: [.t] } } }
Y
out=$(bash "${retrieve}" "${tmp}/langs.yaml")
grep -qx 'languages=\["java","sql"\]' <<<"${out}" || fail "languages: ${out}"
grep -qx 'languages=\["go"\]' <<<"$(bash "${retrieve}" "${tmp}/ci.yaml")" || fail "go languages"
sed 's/language: java/language: rust/' "${tmp}/langs.yaml" > "${tmp}/badlang.yaml"
if bash "${retrieve}" "${tmp}/badlang.yaml" >/dev/null 2>"${tmp}/err"; then fail "rust accepted"; fi
grep -q 'language must be go, java or sql' "${tmp}/err" || fail "language message: $(cat "${tmp}/err")"
echo "ok languages"

ver="v2026.08.1-release-e1f4018"
main=$(ACTOR=hung bash "${resolve}" "${tmp}/ci.yaml" main "${ver}")
[ "$(jq length <<<"${main}")" = 2 ] || fail "main targets: ${main}"
[ "$(jq -r '.[0].file' <<<"${main}")" = "applications/dev/courier.yaml" ] || fail "file substitution"
[ "$(jq -r '.[0].automerge' <<<"${main}")" = "true" ] || fail "env overrides shared automerge"
[ "$(jq -c '.[0].labels' <<<"${main}")" = '["automerge"]' ] || fail "array replaced, not merged: $(jq -c '.[0].labels' <<<"${main}")"
[ "$(jq -c '.[1].labels' <<<"${main}")" = '["worker-only"]' ] || fail "app override"
[ "$(jq -c '.[0].reviewers' <<<"${main}")" = '["hung","someone"]' ] || fail "actor substitution"
[ "$(jq -r '.[0].repo' <<<"${main}")" = "huponx/mm-deploy" ] || fail "shared repo"
[ "$(jq -c '.[0].set' <<<"${main}")" = '[".spec.source.targetRevision"]' ] || fail "default set"

stg=$(bash "${resolve}" "${tmp}/ci.yaml" staging "${ver}")
[ "$(jq length <<<"${stg}")" = 1 ] || fail "staging: disabled for the worker, got ${stg}"
[ "$(jq -r '.[0].repo' <<<"${stg}")" = "huponx/mm-deploy-staging" ] || fail "env repo override"
[ "$(jq -r '.[0].file' <<<"${stg}")" = "applications/staging/courier.yaml" ] || fail "staging file"
[ "$(jq '.[0].set | length' <<<"${stg}")" = 2 ] || fail "env set override"

prod=$(bash "${resolve}" "${tmp}/ci.yaml" production "${ver}")
[ "${prod}" = "[]" ] || fail "enabled false must skip: ${prod}"
none=$(bash "${resolve}" "${tmp}/ci.yaml" nothing "${ver}")
[ "${none}" = "[]" ] || fail "unknown flow"
echo "ok resolve"
