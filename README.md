# actions

Shared composite GitHub Actions. Reference them from any repo of the owner:

```yaml
- uses: huponx/actions/.github/actions/lang-setup@v1
  with:
    lang: go
- uses: huponx/actions/.github/actions/lang-compile@v1
  with:
    lang: go
```

| Action | Purpose |
|---|---|
| [`lang-setup`](.github/actions/lang-setup/action.yml) | install the toolchain and caches for `go`, `java`, `scala` or `rust` |
| [`lang-compile`](.github/actions/lang-compile/action.yml) | compile a project: `go build`, `mvn compile`, `sbt compile`, `cargo check` |

Both take `lang` and `root` (the directory of the language project, default `.`). `lang-setup` also takes `go-version` and `java-version`; `lang-compile` takes `tidy` (`go mod tidy` first, for generation).

Used by `protogen` (`generate.yml`, `check.yml`) with `root` set to the language directory.

Naming: action directories are `<area>-<verb>` (`lang-setup`, `lang-compile`) so unrelated actions added later (for example `npm-publish`, `docker-build`) group together and never collide. Keep new names specific.

## Versions

The whole repo has one version. Every merge to `main` that changes something under `.github/actions/` is released automatically by [`release.yml`](.github/workflows/release.yml):

- a semver tag `vX.Y.Z` and a GitHub Release with generated notes
- the floating major tag `vX` is moved to the same commit

Use it as:

| Reference | Meaning |
|---|---|
| `@v1` | latest `v1.x.y`; gets fixes and features, never breaking changes (recommended) |
| `@v1.2.3` | exact release |
| `@<commit sha>` | immutable, strictest |
| `@main` | unreleased; avoid |

The first release is `v1.0.0`. Later ones are chosen from the commits (conventional commits) that touched `.github/actions/` since the previous release:

| Commit | Bump |
|---|---|
| `type!: ...` or a `BREAKING CHANGE:` line in the body | major |
| `feat: ...` / `feat(scope): ...` | minor |
| anything else (`fix`, `perf`, `refactor`, `docs`, `chore`, ...) | patch |

Changes to the README or to workflows only do not release. Because `main` is squash-merged, the **PR title** becomes the commit subject, so the title must follow the convention (checked by CI):

```
feat(lang-setup): support ruby
fix(lang-compile): build every go.mod below root
feat(lang-compile)!: rename input tidy to mod-tidy
```

A breaking change must be marked (`!` or `BREAKING CHANGE`) so it becomes `v2` and consumers on `@v1` keep working.

To release by hand (or force a different bump, even without action changes): **Actions > Release > Run workflow** and choose `patch`, `minor` or `major`.

## CI

Two workflows run on pull requests:

| Workflow | Job | Checks |
|---|---|---|
| [`ci.yml`](.github/workflows/ci.yml) | `lint` | `actionlint` on the workflows; every `action.yml` has `name`, `description`, `runs.using: composite`, and `shell:` on every `run` step |
| [`ci.yml`](.github/workflows/ci.yml) | `smoke` | runs `lang-setup` and `lang-compile` from the PR's own commit on a tiny Go project |
| [`pr-title.yml`](.github/workflows/pr-title.yml) | `pr-title` | PR title is a conventional commit. Separate workflow so editing the title re-runs only this check |

## Setup (one time)

```bash
REPO=huponx/actions
```

1. **Merge the workflows to `main` first**, while `main` is unprotected.
2. **Repository settings**: squash merge only, so the PR title is the commit subject.
   ```bash
   gh api -X PATCH repos/$REPO -F allow_squash_merge=true -F allow_merge_commit=false \
     -F allow_rebase_merge=false -F delete_branch_on_merge=true \
     -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY
   ```
3. **Token** (optional until you add a tag ruleset): `BOT_TOKEN`, a fine-grained PAT with Contents: Read and write on this repo, owned by an admin.
   ```bash
   gh secret set BOT_TOKEN --repo $REPO     # prompts for the value; or: pbpaste | gh secret set BOT_TOKEN --repo $REPO
   ```
   Without it `release.yml` falls back to `GITHUB_TOKEN`, which works as long as no ruleset restricts tags.
4. **Branch protection** for `main`: save as `main-ruleset.json` and apply.
   ```json
   {
     "name": "protect main",
     "target": "branch",
     "enforcement": "active",
     "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
     "rules": [
       { "type": "deletion" },
       { "type": "non_fast_forward" },
       { "type": "pull_request", "parameters": {
           "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false,
           "require_code_owner_review": false, "require_last_push_approval": false,
           "required_review_thread_resolution": false } },
       { "type": "required_status_checks", "parameters": {
           "strict_required_status_checks_policy": true,
           "required_status_checks": [ { "context": "lint" }, { "context": "pr-title" }, { "context": "smoke" } ] } }
     ],
     "bypass_actors": []
   }
   ```
   Apply it (run from the folder containing the file; the file is only an input, do not commit it):
   ```bash
   gh api repos/$REPO/rulesets --method POST --input main-ruleset.json
   gh api repos/$REPO/rulesets --jq '.[] | {id, name, enforcement}'   # verify
   ```
   Or in the UI: **Settings > Rules > Rulesets > New ruleset > Import a ruleset**, pick the JSON file. The check names (`lint`, `pr-title`, `smoke`) only appear in the picker after each has run once, which is why step 1 comes first. To change it later: `gh api repos/$REPO/rulesets/<id> --method PUT --input main-ruleset.json`.
5. **Tag protection** (optional): release tags `vX.Y.Z` must never move; the floating `vX` tags must be movable by the bot.
   ```json
   {
     "name": "protect release tags",
     "target": "tag",
     "enforcement": "active",
     "conditions": { "ref_name": { "include": ["refs/tags/v*.*.*"], "exclude": [] } },
     "rules": [ { "type": "update" }, { "type": "deletion" }, { "type": "non_fast_forward" } ],
     "bypass_actors": []
   }
   ```
   ```bash
   gh api repos/$REPO/rulesets --method POST --input tag-ruleset.json
   ```
   The pattern `v*.*.*` does not match the floating tags (`v1`), so `release.yml` can still move those. If you also restrict tag *creation*, add the `creation` rule with a bypass for the admin role (`{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}`) and set `BOT_TOKEN`.
6. **Private repo**: allow other repos to use the actions in **Settings > Actions > General > Access** ("Accessible from repositories in the owner").

### Consumers

After the first release exists, point consumers at `@v1` (for example `protogen`'s `generate.yml` and `check.yml`, currently on `@main`).

### Troubleshooting

| Symptom | Cause |
|---|---|
| nothing was released after a merge | no change under `.github/actions/` since the last tag, or `HEAD` is already tagged (see the run summary) |
| released as patch but I expected minor | the PR title did not start with `feat`; with squash merge only the title counts |
| `release.yml` cannot move `v1` | a tag ruleset matches it; use the `v*.*.*` pattern, or set `BOT_TOKEN` and allow the bypass |
| `Unable to resolve action huponx/actions/...@v1` | no release yet, or repo access not allowed (step 6) |
