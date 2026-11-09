#!/usr/bin/env bash
# Turn a git-style unified diff into one self-contained HTML page (side by side, like a GitHub diff).
#
#   scripts/diff-html.sh <changes.diff> <out.html> <title>
#
# Uses diff2html-cli (pinned). The page loads highlight.js assets from cdnjs; if the CLI is
# unavailable a plain offline HTML page is written instead.
set -euo pipefail

diff_file="${1:?usage: $0 <changes.diff> <out.html> <title>}"
out="${2:?usage: $0 <changes.diff> <out.html> <title>}"
title="${3:?usage: $0 <changes.diff> <out.html> <title>}"
version="${DIFF2HTML_VERSION:-5.2.15}"

mkdir -p "$(dirname "${out}")"

if [ ! -s "${diff_file}" ]; then
  cat > "${out}" <<EOF
<!doctype html><meta charset="utf-8"><title>${title}</title>
<body style="font-family:sans-serif;margin:2rem"><h1>${title}</h1><p>No difference in the rendered manifests.</p></body>
EOF
  exit 0
fi

if command -v npx >/dev/null 2>&1 && npx --yes "diff2html-cli@${version}" \
    -i file -s side -t "${title}" -F "${out}" --su hidden -- "${diff_file}" >/dev/null 2>&1 \
    && [ -s "${out}" ]; then
  exit 0
fi

echo "diff2html-cli unavailable, writing a plain HTML page" >&2
python3 - "${diff_file}" "${out}" "${title}" <<'PY'
import html, sys
src, out, title = sys.argv[1:4]
lines = open(src, encoding="utf-8").read().splitlines()
def cls(l):
    if l.startswith("+++") or l.startswith("---") or l.startswith("diff "): return "meta"
    if l.startswith("@@"): return "hunk"
    if l.startswith("+"): return "add"
    if l.startswith("-"): return "del"
    return "ctx"
body = "\n".join(f'<div class="{cls(l)}">{html.escape(l) or "&nbsp;"}</div>' for l in lines)
open(out, "w", encoding="utf-8").write(f"""<!doctype html><meta charset="utf-8"><title>{html.escape(title)}</title>
<style>body{{font:13px/1.5 ui-monospace,Menlo,monospace;margin:2rem}}h1{{font:600 20px sans-serif}}
.add{{background:#e6ffec}}.del{{background:#ffebe9}}.hunk{{background:#ddf4ff;color:#57606a}}.meta{{font-weight:600;margin-top:1rem}}
div{{white-space:pre-wrap}}</style><h1>{html.escape(title)}</h1>{body}""")
PY
