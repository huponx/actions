#!/usr/bin/env bash
# Turn a raw Trivy JSON report into a flat, de-duplicated list of vulnerabilities.
#
#   scripts/normalize.sh <trivy-raw.json> <vulnerabilities.json>
#
# Output file: [{id, pkg, installed, fixed, severity, title, url}] sorted by severity then id.
# Prints "total=N", "critical=N", "high=N", "medium=N", "low=N", "unknown=N" on stdout.
# Needs: jq.
set -euo pipefail

raw="${1:?usage: $0 <trivy-raw.json> <vulnerabilities.json>}"
out="${2:?usage: $0 <trivy-raw.json> <vulnerabilities.json>}"

jq '
  def rank: {"CRITICAL":0,"HIGH":1,"MEDIUM":2,"LOW":3,"UNKNOWN":4}[.] // 5;
  [ (.Results // [])[] | (.Vulnerabilities // [])[]
    | { id: .VulnerabilityID,
        pkg: .PkgName,
        installed: (.InstalledVersion // ""),
        fixed: (.FixedVersion // ""),
        severity: (.Severity // "UNKNOWN"),
        title: ((.Title // "") | gsub("[\r\n]+"; " ")),
        url: (.PrimaryURL // "") } ]
  | unique_by(.id + "|" + .pkg + "|" + .installed)
  | sort_by([(.severity | rank), .id, .pkg])
' "${raw}" > "${out}"

jq -r '
  def n($s): map(select(.severity == $s)) | length;
  "total=\(length)", "critical=\(n("CRITICAL"))", "high=\(n("HIGH"))",
  "medium=\(n("MEDIUM"))", "low=\(n("LOW"))", "unknown=\(n("UNKNOWN"))"
' "${out}"
