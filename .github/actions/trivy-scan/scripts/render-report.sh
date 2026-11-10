#!/usr/bin/env bash
# Render the markdown block of ONE image from the normalised lists written by normalize.sh.
# Shared by every PR comment that shows CVEs (docker-build-scan-push, argocd-cve-report).
#
#   scripts/render-report.sh --new <vulnerabilities.json> [--old <vulnerabilities.json>]
#                            --app <label> --image <repository> [--old-tag <tag>] --new-tag <tag>
#                            [--max-rows N]
#
# Without --old only the current vulnerabilities are shown. With --old the severity table has the
# Before / After / New / Removed columns, new vulnerabilities are marked NEW and the ones that are gone are
# listed in a collapsed section. A vulnerability is identified by CVE id + package: a package upgrade that
# keeps the CVE is not "new".
#
# Output (stdout): "### <app>", the image and tag bullets, the severity table and the collapsed details.
# Needs: jq.
set -euo pipefail

new_file=""; old_file=""; app=""; image=""; old_tag="none"; new_tag=""; max=100
while [ "$#" -gt 0 ]; do
  case "$1" in
    --new) new_file="${2:?--new needs a file}"; shift 2 ;;
    --old) old_file="${2:?--old needs a file}"; shift 2 ;;
    --app) app="${2:?--app needs a value}"; shift 2 ;;
    --image) image="${2:?--image needs a value}"; shift 2 ;;
    --old-tag) old_tag="${2:?--old-tag needs a value}"; shift 2 ;;
    --new-tag) new_tag="${2:?--new-tag needs a value}"; shift 2 ;;
    --max-rows) max="${2:?--max-rows needs a number}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -s "${new_file}" ] || { echo "--new file '${new_file}' is missing or empty" >&2; exit 2; }
[ -n "${app}" ] && [ -n "${image}" ] && [ -n "${new_tag}" ] || { echo "--app, --image and --new-tag are required" >&2; exit 2; }

hasold=false; old_json='[]'
if [ -n "${old_file}" ]; then
  [ -s "${old_file}" ] || { echo "--old file '${old_file}' is missing or empty" >&2; exit 2; }
  hasold=true; old_json=$(cat "${old_file}")
fi

jq -nr \
  --argjson old "${old_json}" --argjson new "$(cat "${new_file}")" --argjson hasold "${hasold}" \
  --argjson max "${max}" --arg app "${app}" --arg image "${image}" --arg oldtag "${old_tag}" --arg newtag "${new_tag}" '
  def k: .id + "|" + .pkg;
  def esc: gsub("\\|"; "\\|");
  def link: if (.id | startswith("CVE-")) then "https://avd.aquasec.com/nvd/" + (.id | ascii_downcase)
            elif (.id | startswith("GHSA-")) then "https://github.com/advisories/" + .id
            elif ((.url // "") != "") then .url else "" end;
  def cve: if link != "" then "[\(.id)](\(link))" else .id end;
  def fix: if .fixed == "" then "-" else "`\(.fixed | esc)`" end;
  def n($l; $s): $l | map(select(.severity == $s)) | length;
  def sevs: ["CRITICAL","HIGH","MEDIUM","LOW","UNKNOWN"];
  def row($mark): "| \(cve) | \(.severity) | `\(.pkg | esc)` | `\(.installed | esc)` | \(fix) | \($mark) |";
  def head: "| CVE | Severity | Package | Installed | Fixed in | Status |\n|---|---|---|---|---|---|";

  ($old | map(k)) as $oldkeys
  | ($new | map(k)) as $newkeys
  | ($new | map(select((k as $x | $oldkeys | index($x)) | not))) as $added
  | ($old | map(select((k as $x | $newkeys | index($x)) | not))) as $removed
  | ($added | map(k)) as $addedkeys
  | [
      "### `\($app)`",
      "",
      "- **Image:** `\($image)`",
      (if $hasold then "- **Tag:** `\($oldtag)` -> `\($newtag)`" else "- **Tag:** `\($newtag)`" end),
      "",
      (if ($new | length) == 0 and ($removed | length) == 0 then "No vulnerability found in the new image."
       elif $hasold then
         "| Severity | Before | After | New | Removed |",
         "|---|---:|---:|---:|---:|",
         (sevs[] as $s | select(n($old; $s) + n($new; $s) > 0) |
            "| \($s) | \(n($old; $s)) | \(n($new; $s)) | \(n($added; $s)) | \(n($removed; $s)) |")
       else
         "| Severity | Count |",
         "|---|---:|",
         (sevs[] as $s | select(n($new; $s) > 0) | "| \($s) | \(n($new; $s)) |")
       end),
      "",
      (if ($new | length) == 0 then empty
       else
         "<details><summary>Current vulnerabilities of the new image (\($new | length))"
         + (if $hasold then ", \($added | length) new" else "" end)
         + "</summary>\n\n"
         + (if $hasold then "**NEW** marks the ones the old image did not have.\n\n" else "" end)
         + head + "\n"
         + ($new | .[0:$max] | map(row(if $hasold and (k as $x | $addedkeys | index($x)) then "**NEW**" else "" end)) | join("\n"))
         + (if ($new | length) > $max then "\n\n_\(($new | length) - $max) more not shown (sorted by severity)._" else "" end)
         + "\n\n</details>"
       end),
      "",
      (if $hasold and ($removed | length) > 0 then
         "<details><summary>Removed since the old image (\($removed | length))</summary>\n\n" + head + "\n"
         + ($removed | .[0:$max] | map(row("removed")) | join("\n"))
         + (if ($removed | length) > $max then "\n\n_\(($removed | length) - $max) more not shown._" else "" end)
         + "\n\n</details>"
       elif $hasold then "No vulnerability was removed." else empty end)
    ] | join("\n")
'
