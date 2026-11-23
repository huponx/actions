#!/usr/bin/env bash
# Test the flyway-lint script on throw-away migration folders.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lint="${here}/.github/actions/flyway-lint/scripts/lint.sh"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mk() {   # folder, file...   (each file gets one line of SQL)
  local d="${tmp}/$1"; shift
  mkdir -p "${d}"
  for f in "$@"; do mkdir -p "${d}/$(dirname "${f}")"; echo "select 1;" > "${d}/${f}"; done
}

mk ok V1__create_users.sql V2__create_orders.sql V2_1__alter.sql V10__more.sql R__views.sql sub/V11__nested.sql
bash "${lint}" "${tmp}/ok" > "${tmp}/out" || fail "valid folder rejected"
grep -q '6 migration' "${tmp}/out" || fail "count: $(cat "${tmp}/out")"
echo "ok valid"

expect_fail() {   # folder, message
  if bash "${lint}" "${tmp}/$1" >/dev/null 2>"${tmp}/err"; then fail "$1 accepted"; fi
  grep -q "$2" "${tmp}/err" || fail "$1 message: $(cat "${tmp}/err")"
}

mk badname V1_create.sql
expect_fail badname 'name must be'
mk badext V1__create.txt
expect_fail badext 'name must be'
mk lower v1__create.sql
expect_fail lower 'name must be'
mk dup V1__a.sql V1__b.sql
expect_fail dup 'version 1 is used by more than one'
mk dupzero V1__a.sql V1.0__b.sql
expect_fail dupzero 'is used by more than one'
mkdir -p "${tmp}/empty" && : > "${tmp}/empty/V1__a.sql"
expect_fail empty 'migration is empty'
mkdir -p "${tmp}/none"
expect_fail none 'no migration found'
expect_fail missing 'migration folder not found'
echo "ok invalid"
