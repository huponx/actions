#!/usr/bin/env bash
# Resolve the deployment targets of one flow from the CI contract.
#
#   scripts/resolve.sh <ci.yaml> <flow> <version>
#
# effective(env) = global.deploy * global.environments.<env> * app.create-deployment-pr.environments.<env>
# (jq deep merge: maps merge, scalars and arrays of the more specific level replace the broader one).
# An env is a target when its `workflows` list contains <flow> and `enabled` is not false.
# `file` and every `set` entry get {app}, {env}, {version} and {actor} substituted (ACTOR env, default empty).
#
# Prints a compact JSON array of targets:
#   [{app, env, repo, repo-owner, repo-name, base-branch, file, set[], reviewers[], labels[], automerge, slack-channel}]
# Needs yq (mikefarah v4) and jq.
set -euo pipefail

file="${1:?usage: $0 <ci.yaml> <flow> <version>}"
flow="${2:?usage: $0 <ci.yaml> <flow> <version>}"
version="${3:?usage: $0 <ci.yaml> <flow> <version>}"
actor="${ACTOR:-}"

yq -o=json '.' "${file}" | jq -c --arg flow "${flow}" --arg version "${version}" --arg actor "${actor}" '
  def subst($app; $env):
    gsub("\\{app\\}"; $app) | gsub("\\{env\\}"; $env) | gsub("\\{version\\}"; $version) | gsub("\\{actor\\}"; $actor);
  def defaults: {"base-branch": "main", "set": [".spec.source.targetRevision"], "reviewers": [], "labels": [],
                 "automerge": false, "slack-channel": ""};
  (.global.deploy // {}) as $shared
  | [ .apps[] as $a
      | ((.global.environments // {}) | to_entries[])
      | select((.value.workflows // []) | index($flow))
      | . as $e
      | (defaults * $shared * ($e.value | del(.workflows)) * ($a."create-deployment-pr".environments[$e.key] // {})) as $cfg
      | select($cfg.enabled != false)
      | {app: $a.name, env: $e.key} as $id
      | $cfg
      | del(.enabled)
      | .file = ((.file // "") | subst($id.app; $id.env))
      | .set = (.set | map(subst($id.app; $id.env)))
      | .reviewers = (.reviewers | map(subst($id.app; $id.env)))
      | . + {"repo-owner": (.repo | split("/")[0]), "repo-name": (.repo | split("/")[1])}
      | $id + .
    ]
  | map(select(.repo != null and .file != ""))'
