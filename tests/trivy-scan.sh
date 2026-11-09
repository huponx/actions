#!/usr/bin/env bash
# Test the normalisation of a Trivy report (no Trivy needed): flat list, de-duplication, counts, order.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "${tmp}/raw.json" <<'JSON'
{"Results":[
 {"Target":"alpine","Vulnerabilities":[
  {"VulnerabilityID":"CVE-2024-0002","PkgName":"zlib","InstalledVersion":"1.2","FixedVersion":"1.3","Severity":"HIGH","Title":"two\nlines","PrimaryURL":"https://avd.aquasec.com/nvd/cve-2024-0002"},
  {"VulnerabilityID":"CVE-2024-0001","PkgName":"openssl","InstalledVersion":"3.0","Severity":"CRITICAL"},
  {"VulnerabilityID":"CVE-2024-0003","PkgName":"curl","InstalledVersion":"8.0","Severity":"LOW"}]},
 {"Target":"app","Vulnerabilities":[
  {"VulnerabilityID":"CVE-2024-0001","PkgName":"openssl","InstalledVersion":"3.0","Severity":"CRITICAL"}]},
 {"Target":"empty"}
]}
JSON
out=$(bash "${here}/.github/actions/trivy-scan/scripts/normalize.sh" "${tmp}/raw.json" "${tmp}/v.json")
grep -qx 'total=3' <<<"${out}" || fail "total: ${out}"
grep -qx 'critical=1' <<<"${out}" || fail "critical: ${out}"
grep -qx 'high=1' <<<"${out}" || fail "high: ${out}"
grep -qx 'low=1' <<<"${out}" || fail "low: ${out}"
[ "$(jq -r '.[0].id' "${tmp}/v.json")" = "CVE-2024-0001" ] || fail "order"
[ "$(jq -r '.[1].title' "${tmp}/v.json")" = "two lines" ] || fail "title newline"
[ "$(jq -r '.[0].fixed' "${tmp}/v.json")" = "" ] || fail "fixed default"
echo '{}' > "${tmp}/none.json"
bash "${here}/.github/actions/trivy-scan/scripts/normalize.sh" "${tmp}/none.json" "${tmp}/n.json" | grep -qx 'total=0' || fail "empty report"
echo "ok normalize"
