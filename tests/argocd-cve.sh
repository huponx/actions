#!/usr/bin/env bash
# Test the cve-plan and cve-report scripts without Trivy, helm or a registry:
# a throw-away git repository and a fake "images of an application" command.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plan_scripts="${here}/.github/actions/argocd-cve-plan/scripts"
report_scripts="${here}/.github/actions/argocd-cve-report/scripts"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Fake: the application file lists its images under `images:`.
cat > "${tmp}/images.sh" <<'FAKE'
#!/usr/bin/env bash
[ -s "$1" ] || exit 0
yq '.images[]' "$1" | sort -u
FAKE
chmod +x "${tmp}/images.sh"

repo="${tmp}/repo"
mkdir -p "${repo}/applications/dev"
cd "${repo}"
git init -q
git config user.email t@t; git config user.name t
cat > applications/dev/web.yaml <<'Y'
images: ["ghcr.io/o/web:1.0", "docker.io/library/redis:7", "localhost:5000/side/car:1"]
Y
cat > applications/dev/gone.yaml <<'Y'
images: ["ghcr.io/o/gone:1"]
Y
git add -A; git commit -qm base
base=$(git rev-parse HEAD)
cat > applications/dev/web.yaml <<'Y'
images: ["ghcr.io/o/web:1.1", "docker.io/library/redis:7", "ghcr.io/o/extra:2", "localhost:5000/side/car@sha256:abc"]
Y
git rm -q applications/dev/gone.yaml
git commit -qam change

BASE_SHA="${base}" WORK="${tmp}/w" IMAGES_CMD="${tmp}/images.sh" bash "${plan_scripts}/cve-plan.sh" >/dev/null
plan="${tmp}/w/plan.json"
[ "$(jq '.items | length' "${plan}")" = 4 ] || fail "items: $(jq -c .items "${plan}")"
jq -e '.items[] | select(.key=="docker.io/library/redis")' "${plan}" >/dev/null && fail "unchanged image listed"
jq -e '.items[] | select(.key=="ghcr.io/o/web" and .old=="ghcr.io/o/web:1.0" and .new=="ghcr.io/o/web:1.1")' "${plan}" >/dev/null || fail "changed pair"
jq -e '.items[] | select(.key=="ghcr.io/o/extra" and .old==null)' "${plan}" >/dev/null || fail "added image"
jq -e '.items[] | select(.app=="dev/gone" and .new==null)' "${plan}" >/dev/null || fail "removed image"
jq -e '.items[] | select(.key=="localhost:5000/side/car" and .old=="localhost:5000/side/car:1")' "${plan}" >/dev/null || fail "registry with port"
[ "$(jq '.scans | length' "${plan}")" = 5 ] || fail "scans: $(jq -c .scans "${plan}")"
[ "$(jq -c '.include | length' "${tmp}/w/matrix.json")" = 5 ] || fail "matrix"
echo "ok plan"

# Scan results: web 1.0 has A (critical), B (high), C (low); web 1.1 has B (same), C (other version), D (new high).
put() {   # image, json
  local id; id=$(jq -r --arg i "$1" '.scans[] | select(.image == $i) | .id' "${plan}")
  mkdir -p "${tmp}/s/cve-${id}"; echo "$2" > "${tmp}/s/cve-${id}/vulnerabilities.json"
}
v() { printf '{"id":"%s","pkg":"%s","installed":"%s","fixed":"%s","severity":"%s","title":"","url":""}' "$@"; }
put ghcr.io/o/web:1.0 "[$(v CVE-1 openssl 1 2 CRITICAL),$(v CVE-2 zlib 1 '' HIGH),$(v CVE-3 curl 1 2 LOW)]"
put ghcr.io/o/web:1.1 "[$(v CVE-2 zlib 1 '' HIGH),$(v CVE-3 curl 2 3 LOW),$(v CVE-4 glibc 1 2 HIGH)]"
put ghcr.io/o/extra:2 "[$(v GHSA-x-y-z lib 1 2 MEDIUM)]"
put localhost:5000/side/car:1 "[]"
put 'localhost:5000/side/car@sha256:abc' "[$(v CVE-9 busybox 1 '' CRITICAL)]"

FAIL_ON_NEW=CRITICAL,HIGH MAX_ROWS=100 bash "${report_scripts}/cve-report.sh" "${plan}" "${tmp}/s" "${tmp}/o" >/dev/null
c="${tmp}/o/comment.md"
grep -q '<!-- cve-diff -->' "${c}" || fail "marker"
grep -qE '\[CVE-4\].*\| \*\*NEW\*\* \|$' "${c}" || fail "CVE-4 not marked new"
! grep -E '\[CVE-2\]' "${c}" | grep -q 'NEW' || fail "CVE-2 should not be new"
grep -E '\[CVE-3\]' "${c}" | grep -qv 'NEW' || fail "CVE-3 (version bump only) should not be new"
grep -qE '\[CVE-1\].*\| removed \|$' "${c}" || fail "CVE-1 not listed as removed"
grep -q 'https://avd.aquasec.com/nvd/cve-4' "${c}" || fail "cve link"
grep -q 'github.com/advisories/GHSA-x-y-z' "${c}" || fail "ghsa link"
grep -q 'Image removed from the application' "${c}" || fail "removed image note"
# gate: CVE-4 (HIGH) in web, CVE-9 (CRITICAL) in the car image; GHSA is MEDIUM
[ "$(cat "${tmp}/o/gate")" = 2 ] || fail "gate=$(cat "${tmp}/o/gate")"
grep -q 'this check fails' "${c}" || fail "gate message"
# shellcheck disable=SC2016  # backticks are literal markdown
grep -qF -- '- **Image:** `ghcr.io/o/web`' "${c}" || fail "image line"
# shellcheck disable=SC2016
grep -qF -- '- **Tag:** `1.0` -> `1.1`' "${c}" || fail "tag line"
# shellcheck disable=SC2016
grep -qF -- '- **Tag:** `1` -> `removed`' "${c}" || fail "removed tag line"
[ "$(grep -c '<details>' "${c}")" = "$(grep -c '^</details>$' "${c}")" ] || fail "unbalanced details"
grep -q '<details><summary>Current vulnerabilities of the new image (3), 1 new</summary>' "${c}" || fail "current vulnerabilities not collapsible"
echo "ok report"

# No gate configured, nothing changed.
bash "${report_scripts}/cve-report.sh" "${plan}" "${tmp}/s" "${tmp}/o2" >/dev/null
[ "$(cat "${tmp}/o2/gate")" = 0 ] || fail "gate without FAIL_ON_NEW"
echo '{"scans":[],"items":[]}' > "${tmp}/empty.json"
bash "${report_scripts}/cve-report.sh" "${tmp}/empty.json" "${tmp}/s" "${tmp}/o3" >/dev/null
grep -q 'No container image changed' "${tmp}/o3/comment.md" || fail "empty plan"
echo "ok empty"
