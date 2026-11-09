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
| [`trivy-scan`](.github/actions/trivy-scan/action.yml) | scan a container image for CVEs with Trivy and write a normalised JSON list (id, package, installed/fixed version, severity); optional fail on severity |
| [`argocd-repo-validate`](.github/actions/argocd-repo-validate/action.yml) | GitOps repo of ArgoCD Applications: yamllint (bundled config), policy checks, kubeconform with the ArgoCD CRD schemas |
| [`argocd-cve-plan`](.github/actions/argocd-cve-plan/action.yml) | PR: render old and new chart revisions of changed Applications, output a matrix of the images to scan |
| [`argocd-cve-report`](.github/actions/argocd-cve-report/action.yml) | PR: compare the scans of the old and the new image, sticky comment with NEW and removed CVEs, optional gate |
| [`argocd-manifest-diff`](.github/actions/argocd-manifest-diff/action.yml) | on a PR that changes ArgoCD Applications: render both chart revisions, publish a side-by-side HTML diff to a GitHub Pages repo, keep one PR comment with the changed resources and compare links |

Both take `lang` and `root` (the directory of the language project, default `.`). `lang-setup` also takes `go-version` and `java-version`; `lang-compile` takes `tidy` (`go mod tidy` first, for generation).

Used by `protogen` (`generate.yml`, `check.yml`) with `root` set to the language directory.

## trivy-scan

Scans one image reference and writes `vulnerabilities.json`, a flat de-duplicated list `[{id, pkg, installed, fixed, severity, title, url}]` sorted by severity, next to the raw Trivy report. The normalised list is what two scans are compared with (see `mm-deploy`, workflow `cve.yml`).

```yaml
- uses: huponx/actions/.github/actions/trivy-scan@v1
  id: scan
  with:
    image: ghcr.io/huponx/x-noti:1.2.3
    registry-username: ${{ github.actor }}       # private image only
    registry-password: ${{ secrets.GITHUB_TOKEN }}
    fail-on-severity: CRITICAL                   # optional
- run: jq length "${{ steps.scan.outputs.vulnerabilities }}"
```

| Input | Default | Meaning |
|---|---|---|
| `image` (required) | | image reference |
| `severity` | `UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL` | severities to report |
| `ignore-unfixed` | `false` | hide vulnerabilities without a fix |
| `registry-username`, `registry-password` | empty | credentials for a private registry |
| `trivy-version` | `latest` | Trivy to install (DB cached by `setup-trivy`) |
| `timeout` | `10m` | scan timeout |
| `output-dir` | `$RUNNER_TEMP/trivy-scan` | where the files are written |
| `fail-on-severity` | empty | comma separated severities that fail the step |
| `summary` | `true` | severity table in the job summary |

Outputs: `vulnerabilities`, `report` (paths), `total`, `critical`, `high`, `medium`, `low`. Only vulnerabilities (no secrets or misconfiguration) are scanned. Trivy downloads its vulnerability database from `ghcr.io/aquasecurity/trivy-db`; a runner that cannot reach it fails the scan.

## argocd-repo-validate, argocd-cve-plan, argocd-cve-report

Used by the GitOps repository `mm-deploy`, which keeps only ArgoCD manifests and thin workflows.

- `argocd-repo-validate` (inputs `applications-path`, `paths`, tool versions): run after checkout. Policy: kind and apiVersion, `metadata.name` equals the file name, the ArgoCD finalizer, pinned `targetRevision`, no inline secret values, automated sync.
- `argocd-cve-plan` (input `github-token`): run with `fetch-depth: 0`. Outputs `matrix` (feed `strategy.matrix` of a job that calls `trivy-scan` and uploads `vulnerabilities.json` as artifact `cve-<id>`) and `images`; uploads `plan.json`. Images are paired by repository; unchanged ones are skipped.
- `argocd-cve-report` (inputs `github-token`, `images`, `fail-on-new`, `max-rows`): downloads the plan and the scans, comments (marker `<!-- cve-diff -->`: severity table, current CVEs with **NEW** marks, removed CVEs) and fails when `fail-on-new` severities were introduced. A CVE is identified by id and package. Tested by [`tests/argocd-cve.sh`](tests/argocd-cve.sh).

See `mm-deploy/.github/workflows/cve.yml` for the three jobs wired together.

## argocd-manifest-diff

For a GitOps repository that holds ArgoCD `Application` manifests (Helm charts from an OCI registry). On a pull request it:

1. finds the `applications/*.yaml` files changed against the PR base (added, modified, deleted, renames counted as delete + add);
2. renders the chart of the old and the new side with `helm template` (`targetRevision` and `valuesObject` of each side), one normalised file per Kubernetes resource;
3. writes a side-by-side HTML diff (`diff2html`, GitHub-like) to a GitHub Pages repository at `<app>/<old>...<new>.html`;
4. keeps one sticky PR comment: the table of Added / Removed / Changed resources, the HTML link, the compare links of the service repository (`..` direct diff of two commits, `...` commits since the common ancestor) and the first lines of the manifest diff.

```yaml
# .github/workflows/diff.yml in the GitOps repository
name: Diff
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
  pull-requests: write
jobs:
  diff:                                   # make this job a required check
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0                  # the base commit must be available
      - uses: huponx/actions/.github/actions/argocd-manifest-diff@v1
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          diffs-token: ${{ secrets.BOT_TOKEN }}
          diffs-repo: huponx/mm-deploy-diffs
          diffs-base-url: https://huponx.github.io/mm-deploy-diffs
```

| Input | Default | Meaning |
|---|---|---|
| `github-token` (required) | | comment on the PR, read charts from GHCR |
| `diffs-token` (required) | | PAT with Contents read/write on the Pages repo (`GITHUB_TOKEN` cannot push to another repo) |
| `diffs-repo`, `diffs-base-url` (required) | | Pages repo (`owner/repo`) and its public URL |
| `diffs-branch` | `main` | branch served by Pages |
| `diffs-path` | empty | folder in the Pages repo; only this folder is written, so it can share a site |
| `applications-path` | `applications` | folder with the Application manifests |
| `base-sha` | PR base | commit to compare against |
| `helm-version` | `v3.16.4` | |
| `preview-lines` | `300` | lines of the manifest diff shown in the comment |
| `keep-days` | `90` | pages older than this are deleted on the next publish (0 = keep) |
| `comment` | `true` | post or update the comment |
| `fail-on-publish-error` | `true` | fail when the pages cannot be published (keep `true` for a required check) |

Outputs: `changed` (number of changed Application files) and `urls` (page URLs, one per line).

Behaviour to know:

- A **required** check must never stay pending, so make the job unconditional (no `paths:` filter on the workflow). The action succeeds without a comment when no Application changed, and succeeds with a notice on fork PRs (no secrets there).
- The runner needs `helm`, `yq`, `jq`, `git` and `curl` (all present on `ubuntu-latest`). Charts are pulled with `github-token`: they must be public, or the repository needs Read access in the chart package settings.
- The service repository is `<owner of the chart registry path>/<application name>`; override it per Application with the annotation `argocd-manifest-diff/source-repo: owner/repo`. The commit is read from the revision suffix (`1.20260813.4-main-e1f4018` gives `e1f4018`), else from the tag `v<version>`.
- The pages are public and not redacted: rendered values, hostnames and Secret names are readable. Do not put secrets in `valuesObject`.
- The scripts in [`scripts/`](.github/actions/argocd-manifest-diff/scripts) run locally too (`render-app.sh`, `diff-render.sh`, `diff-html.sh`, `compare-links.sh`, `pr-diff.sh`, `publish-pages.sh`); [`tests/argocd-manifest-diff.sh`](tests/argocd-manifest-diff.sh) exercises them end to end with a local chart.

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

Two workflows run on pull requests (the `lint` job also runs `shellcheck` on the action scripts and tests):

| Workflow | Job | Checks |
|---|---|---|
| [`ci.yml`](.github/workflows/ci.yml) | `lint` | `actionlint` on the workflows; every `action.yml` has `name`, `description`, `runs.using: composite`, and `shell:` on every `run` step |
| [`ci.yml`](.github/workflows/ci.yml) | `smoke` | runs `lang-setup` and `lang-compile` from the PR's own commit on a tiny Go project |
| [`ci.yml`](.github/workflows/ci.yml) | `test-argocd-manifest-diff` | runs [`tests/argocd-manifest-diff.sh`](tests/argocd-manifest-diff.sh) (report, HTML and publish to a local bare repo) and [`tests/trivy-scan.sh`](tests/trivy-scan.sh) (report normalisation) |
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
           "required_status_checks": [ { "context": "lint" }, { "context": "pr-title" }, { "context": "smoke" },
             { "context": "test-argocd-manifest-diff" } ] } }
     ],
     "bypass_actors": []
   }
   ```
   Apply it (run from the folder containing the file; the file is only an input, do not commit it):
   ```bash
   gh api repos/$REPO/rulesets --method POST --input main-ruleset.json
   gh api repos/$REPO/rulesets --jq '.[] | {id, name, enforcement}'   # verify
   ```
   Or in the UI: **Settings > Rules > Rulesets > New ruleset > Import a ruleset**, pick the JSON file. The check names (`lint`, `pr-title`, `smoke`, `test-argocd-manifest-diff`) only appear in the picker after each has run once, which is why step 1 comes first. To change it later: `gh api repos/$REPO/rulesets/<id> --method PUT --input main-ruleset.json`.
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

Point consumers at `@v1` (`protogen`'s `generate.yml` and `check.yml` already do). When a breaking release creates `v2`, consumers move to `@v2` on their own schedule.

### Troubleshooting

| Symptom | Cause |
|---|---|
| nothing was released after a merge | no change under `.github/actions/` since the last tag, or `HEAD` is already tagged (see the run summary) |
| released as patch but I expected minor | the PR title did not start with `feat`; with squash merge only the title counts |
| `release.yml` cannot move `v1` | a tag ruleset matches it; use the `v*.*.*` pattern, or set `BOT_TOKEN` and allow the bypass |
| `Unable to resolve action huponx/actions/...@v1` | no release yet, or repo access not allowed (step 6) |
