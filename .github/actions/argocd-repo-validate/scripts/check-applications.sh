#!/usr/bin/env bash
# Policy checks for ArgoCD Application manifests in applications/ and infra-services/.
#   scripts/check-applications.sh [file...]    (default: $APPLICATIONS_PATH/*.yaml, APPLICATIONS_PATH=applications)
set -euo pipefail

command -v yq >/dev/null || { echo "yq is required" >&2; exit 2; }

files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
  shopt -s nullglob
  files=("${APPLICATIONS_PATH:-applications}"/*.yaml)
fi

fail=0
err() { echo "::error file=$1::$2"; fail=1; }

for f in "${files[@]}"; do
  [ -f "${f}" ] || { err "${f}" "file not found"; continue; }
  base=$(basename "${f}" .yaml)

  [ "$(yq '.kind' "${f}")" = "Application" ] || err "${f}" "kind must be Application"
  [ "$(yq '.apiVersion' "${f}")" = "argoproj.io/v1alpha1" ] || err "${f}" "apiVersion must be argoproj.io/v1alpha1"

  name=$(yq '.metadata.name' "${f}")
  [ "${name}" = "${base}" ] || err "${f}" "metadata.name '${name}' must match the file name '${base}'"

  [ "$(yq '.metadata.finalizers | contains(["resources-finalizer.argocd.argoproj.io"])' "${f}")" = "true" ] \
    || err "${f}" "metadata.finalizers must contain resources-finalizer.argocd.argoproj.io"

  repo=$(yq '.spec.source.repoURL // ""' "${f}")
  [ -n "${repo}" ] || err "${f}" "spec.source.repoURL is required"

  rev=$(yq '.spec.source.targetRevision // ""' "${f}")
  case "${rev}" in
    ""|latest|HEAD|main|master|"*") err "${f}" "spec.source.targetRevision must be a pinned version, got '${rev}'" ;;
  esac
  # A YAML number such as 1.20 would silently lose digits: require a string.
  [ "$(yq '.spec.source.targetRevision | tag' "${f}")" = "!!str" ] \
    || err "${f}" "spec.source.targetRevision must be a quoted string"

  [ -n "$(yq '.spec.destination.name // ""' "${f}")" ] || err "${f}" "spec.destination.name is required"
  [ "$(yq '.spec.syncPolicy.automated != null' "${f}")" = "true" ] || err "${f}" "spec.syncPolicy.automated is required"

  # Secret literals must never be committed: reference existing Secrets instead.
  lits=$(yq '.. | select(tag == "!!str") | select((path | .[-1] | tostring) | test("(?i)^(password|passwd|token|apikey|api_key|private_key|[a-z_]*_(password|token|secret))$")) | path | join(".")' "${f}" 2>/dev/null || true)
  if [ -n "${lits}" ]; then
    while read -r p; do err "${f}" "possible secret literal at ${p}; use secrets[].secretName/key instead"; done <<<"${lits}"
  fi
done

shopt -s nullglob
for f in infra-services/*.yaml infra-services/*/*.yaml; do
  if yq -e 'select(.kind == "Secret") | select(.data != null or .stringData != null)' "${f}" >/dev/null 2>&1; then
    err "${f}" "Secret with data must not be committed"
  fi
done

[ "${fail}" -eq 0 ] && echo "applications ok (${#files[@]} file(s))"
exit "${fail}"
