#!/usr/bin/env bash
# Validate the CI contract and print the app matrix.
#
#   scripts/retrieve.sh <ci.yaml>
#
# Stdout (key=value, ready for $GITHUB_OUTPUT):
#   apps=<compact JSON array>          one entry per app (defaults applied)
#   environments=<compact JSON array>  names under global.environments
#   count=<number of apps>
# Unknown keys and missing required keys fail with ::error:: lines. Needs yq (mikefarah v4) and jq.
set -euo pipefail

file="${1:?usage: $0 <ci.yaml>}"
[ -f "${file}" ] || { echo "::error::contract not found: ${file}" >&2; exit 1; }

json=$(yq -o=json '.' "${file}")

errors=$(jq -r '
  def unknown($o; $allowed; $where):
    if ($o | type) != "object" then "\($where): must be a map"
    else ($o | keys - $allowed | map("\($where): unknown key \(.)") | .[]) end;
  def deploy_keys: ["enabled","repo","base-branch","file","set","reviewers","labels","automerge","slack-channel"];

  unknown(.; ["apps","global"]; "root"),
  (if ((.apps // []) | type) != "array" or ((.apps // []) | length) == 0 then "apps: at least one app is required" else empty end),
  ((.apps // [])[]? as $a
    | ($a.name // "?") as $n
    | unknown($a; ["name","language","cicd","create-deployment-pr"]; "apps[\($n)]"),
      (if ($a.name // "") == "" then "apps[\($n)]: name is required" else empty end),
      (if ($a.language // "") != "go" then "apps[\($n)]: language must be go" else empty end),
      (($a.cicd.jobs."containerize-and-package") as $j
        | if $j == null then "apps[\($n)]: cicd.jobs.containerize-and-package is required"
          else unknown($j; ["image-name","dockerfile-path","chart-path","image-tag-paths","trivy"]; "apps[\($n)].containerize-and-package"),
               (["image-name","dockerfile-path","chart-path"][] as $k | if ($j[$k] // "") == "" then "apps[\($n)]: \($k) is required" else empty end),
               (if (($j."image-tag-paths" // []) | length) == 0 then "apps[\($n)]: image-tag-paths is required" else empty end),
               (if $j.trivy != null then unknown($j.trivy; ["severity","ignore-unfixed","exit-code"]; "apps[\($n)].trivy") else empty end)
          end),
      (if $a."create-deployment-pr" != null then
         unknown($a."create-deployment-pr"; ["environments"]; "apps[\($n)].create-deployment-pr"),
         (($a."create-deployment-pr".environments // {}) | to_entries[] | unknown(.value; deploy_keys; "apps[\($n)].create-deployment-pr.environments.\(.key)"))
       else empty end)),
  (if .global != null then
     unknown(.global; ["deploy","environments"]; "global"),
     (if .global.deploy != null then unknown(.global.deploy; deploy_keys; "global.deploy") else empty end),
     ((.global.environments // {}) | to_entries[] | unknown(.value; deploy_keys + ["workflows"]; "global.environments.\(.key)"))
   else empty end)
' <<<"${json}")

if [ -n "${errors}" ]; then
  while IFS= read -r line; do echo "::error file=${file}::${line}" >&2; done <<<"${errors}"
  exit 1
fi

jq -c '[.apps[] | (.cicd.jobs."containerize-and-package") as $j | {
  name: .name,
  language: .language,
  "image-name": $j."image-name",
  "dockerfile-path": $j."dockerfile-path",
  "chart-path": $j."chart-path",
  "image-tag-paths": $j."image-tag-paths",
  "trivy-severity": ($j.trivy.severity // "HIGH,CRITICAL"),
  "trivy-ignore-unfixed": ((if $j.trivy."ignore-unfixed" == null then true else $j.trivy."ignore-unfixed" end) | tostring),
  "trivy-fail": ((($j.trivy."exit-code" // 1) | tonumber) != 0 | tostring)
}]' <<<"${json}" | sed 's/^/apps=/'
jq -c '[(.global.environments // {}) | keys_unsorted[]]' <<<"${json}" | sed 's/^/environments=/'
jq -r '"count=\(.apps | length)"' <<<"${json}"
