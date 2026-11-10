#!/usr/bin/env bash
# Test of trivy-scan/scripts/render-report.sh, the renderer shared by every CVE comment.
# The backticks in the expected strings are literal markdown, not command substitutions.
# shellcheck disable=SC2016
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
render="${here}/../.github/actions/trivy-scan/scripts/render-report.sh"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
fail() { echo "FAIL: $*"; [ ! -f "${tmp}/out.md" ] || cat "${tmp}/out.md"; exit 1; }

v() { printf '{"id":"%s","pkg":"%s","installed":"%s","fixed":"%s","severity":"%s","title":"","url":"%s"}' "$@"; }
echo "[$(v CVE-1 openssl 1 2 CRITICAL ''),$(v CVE-2 zlib 1 '' HIGH ''),$(v CVE-3 curl 1 2 LOW '')]" > "${tmp}/old.json"
echo "[$(v CVE-2 zlib 1 '' HIGH ''),$(v CVE-3 curl 2 3 LOW ''),$(v CVE-4 'a|b' 1 2 UNKNOWN ''),$(v GHSA-x-y-z lib 1 2 MEDIUM '')]" > "${tmp}/new.json"
echo '[]' > "${tmp}/empty.json"
out="${tmp}/out.md"

# Without an old list: current vulnerabilities only.
bash "${render}" --new "${tmp}/new.json" --app courier --image ghcr.io/o/courier --new-tag 1.1 > "${out}"
grep -qxF '### `courier`' "${out}" || fail "heading"
grep -qxF -- '- **Image:** `ghcr.io/o/courier`' "${out}" || fail "image bullet"
grep -qxF -- '- **Tag:** `1.1`' "${out}" || fail "tag bullet without old"
grep -qxF '| Severity | Count |' "${out}" || fail "count table"
grep -qxF '| UNKNOWN | 1 |' "${out}" || fail "unknown is counted"
grep -qF '<details><summary>Current vulnerabilities of the new image (4)</summary>' "${out}" || fail "details summary"
grep -qF 'a\|b' "${out}" || fail "pipe is escaped"
grep -qF 'https://github.com/advisories/GHSA-x-y-z' "${out}" || fail "ghsa link"
grep -qF 'https://avd.aquasec.com/nvd/cve-2' "${out}" || fail "nvd link"
! grep -q 'NEW' "${out}" || fail "no NEW mark without old list"
! grep -q 'Removed since' "${out}" || fail "no removed section without old list"
echo "ok render single"

# With an old list: columns, NEW mark, removed section.
bash "${render}" --old "${tmp}/old.json" --new "${tmp}/new.json" --app dev/web --image ghcr.io/o/web --old-tag 1.0 --new-tag 1.1 > "${out}"
grep -qxF -- '- **Tag:** `1.0` -> `1.1`' "${out}" || fail "tag bullet with old"
grep -qxF '| Severity | Before | After | New | Removed |' "${out}" || fail "comparison table"
grep -qxF '| CRITICAL | 1 | 0 | 0 | 1 |' "${out}" || fail "removed critical counted"
grep -qF '(4), 2 new</summary>' "${out}" || fail "new counted in summary"
grep -qE '\[CVE-4\].*\| \*\*NEW\*\* \|$' "${out}" || fail "CVE-4 is new"
grep -E '\[CVE-3\]' "${out}" | grep -qv 'NEW' || fail "version bump only is not new"
grep -qE '\[CVE-1\].*\| removed \|$' "${out}" || fail "CVE-1 listed as removed"
[ "$(grep -c '<details>' "${out}")" = "$(grep -c '^</details>$' "${out}")" ] || fail "unbalanced details"
echo "ok render compare"

# Nothing found, with and without old list, and --max-rows.
bash "${render}" --new "${tmp}/empty.json" --app c --image r --new-tag 1 > "${out}"
grep -qF 'No vulnerability found' "${out}" || fail "empty list"
! grep -q '<details>' "${out}" || fail "no details when empty"
bash "${render}" --new "${tmp}/new.json" --app c --image r --new-tag 1 --max-rows 1 > "${out}"
grep -qF '3 more not shown' "${out}" || fail "max rows"
echo "ok render limits"

# Bad usage.
if bash "${render}" --new "${tmp}/new.json" --app c >/dev/null 2>&1; then fail "missing arguments accepted"; fi
if bash "${render}" --new "${tmp}/missing.json" --app c --image r --new-tag 1 >/dev/null 2>&1; then fail "missing file accepted"; fi
echo "ok render usage"
