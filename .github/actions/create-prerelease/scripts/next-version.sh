#!/usr/bin/env bash
# Decide the release version of a staging build: v<YYYY>.<MM>.N-release-<short-sha>.
#
#   scripts/next-version.sh <releases.json> <YYYY> <MM> <short-sha>
#
# <releases.json> is an array of {tag_name, prerelease}. Rule for N within the month:
#   - no release this month            -> N = 1
#   - highest N is still a pre-release -> same N, only the short sha changes
#   - highest N was published          -> N + 1
# Prints key=value lines: tag, exists (true when this exact tag is already there: idempotent re-run),
# superseded (space separated unpublished pre-release tags of the same N with another sha).
# Needs jq.
set -euo pipefail

releases="${1:?usage: $0 <releases.json> <YYYY> <MM> <short-sha>}"
year="${2:?usage: $0 <releases.json> <YYYY> <MM> <short-sha>}"
month="${3:?usage: $0 <releases.json> <YYYY> <MM> <short-sha>}"
sha="${4:?usage: $0 <releases.json> <YYYY> <MM> <short-sha>}"
month=$(printf '%02d' "$((10#${month}))")

jq -r --arg year "${year}" --arg month "${month}" --arg sha "${sha}" '
  [ .[] | select(.draft != true) | .tag_name as $t
      | ($t | capture("^v" + $year + "\\." + $month + "\\.(?<n>[0-9]+)-release-(?<sha>.+)$")?) as $m
      | select($m != null)
      | {tag: $t, n: ($m.n | tonumber), sha: $m.sha, pre: (.prerelease == true)} ] as $rel
  | ($rel | map(.n) | max // 0) as $max
  | ($rel | map(select(.n == $max))) as $top
  | (if $max == 0 then 1
     elif ($top | any(.pre | not)) then $max + 1
     else $max end) as $n
  | ("v" + $year + "." + $month + "." + ($n | tostring) + "-release-" + $sha) as $tag
  | "tag=\($tag)",
    "exists=\(($rel | any(.tag == $tag)) )",
    "superseded=\(($rel | map(select(.n == $n and .pre and .tag != $tag) | .tag) | join(" ")))"
' "${releases}"
