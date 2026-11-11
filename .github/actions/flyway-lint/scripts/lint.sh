#!/usr/bin/env bash
# Check the file names of a Flyway migration folder. The content of the SQL is NOT analysed.
#
#   scripts/lint.sh [folder]        (default: migrations/sql)
#
# Rules (every violation is reported, then the exit code is 1):
#   - every file is V<version>__<description>.sql (versioned) or R__<description>.sql (repeatable)
#   - <version> is digits separated by "." or "_" (1, 2, 1.1, 2_3); two files must not share a version
#   - the file is not empty
# Subfolders are scanned too (Flyway reads them recursively).
set -euo pipefail

dir="${1:-migrations/sql}"
[ -d "${dir}" ] || { echo "::error::migration folder not found: ${dir}" >&2; exit 1; }

errors=0
fail() { echo "::error file=$1::$2" >&2; errors=$((errors + 1)); }

files=()
while IFS= read -r f; do files+=("${f}"); done < <(find "${dir}" -type f ! -name '.*' | LC_ALL=C sort)
[ "${#files[@]}" -gt 0 ] || { echo "::error::no migration found in ${dir}" >&2; exit 1; }

seen=""
for f in "${files[@]}"; do
  name="$(basename "${f}")"
  if [[ "${name}" =~ ^V([0-9]+([._][0-9]+)*)__[^/]+\.sql$ ]]; then
    version="${BASH_REMATCH[1]//_/.}"
    # 1.0 and 1 are the same version for Flyway: compare without trailing ".0".
    norm="${version}"
    while [[ "${norm}" == *.0 ]]; do norm="${norm%.0}"; done
    case " ${seen} " in
      *" ${norm}:"*) fail "${f}" "version ${version} is used by more than one migration" ;;
    esac
    seen="${seen} ${norm}:"
  elif [[ "${name}" =~ ^R__[^/]+\.sql$ ]]; then
    :
  else
    fail "${f}" "name must be V<version>__<description>.sql or R__<description>.sql"
    continue
  fi
  [ -s "${f}" ] || fail "${f}" "migration is empty"
done

if [ "${errors}" -gt 0 ]; then
  echo "flyway-lint: ${errors} problem(s) in ${dir}" >&2
  exit 1
fi
echo "flyway-lint: ${#files[@]} migration(s) in ${dir} look fine"
