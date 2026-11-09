#!/usr/bin/env bash
# Test of pr-comment/scripts/comment.sh with a fake `gh` that records its calls.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../.github/actions/pr-comment/scripts/comment.sh"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin"

cat > "${tmp}/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "${CALLS}"
case "$*" in
  *"/comments --paginate"*) cat "${EXISTING}" ;;
  *) : ;;
esac
GH
chmod +x "${tmp}/bin/gh"

export PATH="${tmp}/bin:${PATH}" CALLS="${tmp}/calls" EXISTING="${tmp}/existing"
export GH_TOKEN=x GITHUB_REPOSITORY=o/r PR_NUMBER=7 MARKER='<!-- m -->' BODY_FILE="${tmp}/body.md"
printf '<!-- m -->\nhello\n' > "${BODY_FILE}"
fail() { echo "FAIL: $*"; cat "${CALLS}" 2>/dev/null || true; exit 1; }

# no existing comment -> POST
: > "${EXISTING}"; : > "${CALLS}"
[ "$(bash "${script}" 2>/dev/null)" = "action=created" ] || fail "created"
grep -q -- '-X POST repos/o/r/issues/7/comments' "${CALLS}" || fail "POST call"

# existing comment -> PATCH
echo 99 > "${EXISTING}"; : > "${CALLS}"
[ "$(bash "${script}" 2>/dev/null)" = "action=updated" ] || fail "updated"
grep -q -- '-X PATCH repos/o/r/issues/comments/99' "${CALLS}" || fail "PATCH call"

# create=false and nothing to update -> skipped, no POST
: > "${EXISTING}"; : > "${CALLS}"
[ "$(CREATE=false bash "${script}" 2>/dev/null)" = "action=skipped" ] || fail "create=false"
! grep -q -- '-X POST' "${CALLS}" || fail "no POST expected"

# fork and missing PR -> skipped without any API call
: > "${CALLS}"
[ "$(IS_FORK=true bash "${script}" 2>/dev/null)" = "action=skipped" ] || fail "fork"
[ "$(PR_NUMBER='' bash "${script}" 2>/dev/null)" = "action=skipped" ] || fail "no pr"
[ ! -s "${CALLS}" ] || fail "no API call expected"

# body without the marker is an error
printf 'no marker\n' > "${BODY_FILE}"
if bash "${script}" >/dev/null 2>&1; then fail "marker check"; fi

echo "ok pr-comment"
